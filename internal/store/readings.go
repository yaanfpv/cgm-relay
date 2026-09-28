package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

// HistoryGap is how close, in time, a history reading must be to an
// already-stored reading before StorePoll treats it as a near-duplicate
// and skips it.
const HistoryGap = 150 * time.Second

// DefaultRetention is how long a reading is kept before Prune removes it.
const DefaultRetention = 15 * 24 * time.Hour

// ErrInvalidReading is wrapped in a ReadingResult's Err by StorePoll when a
// reading has a zero Time or a non-positive MgDl value. Nothing is stored
// for that reading; every other reading passed to the same call is still
// decided on its own.
var ErrInvalidReading = errors.New("store: invalid reading")

// PollOutcome is what happened to one reading passed to StorePoll.
type PollOutcome int

const (
	// PollStored means the reading was written.
	PollStored PollOutcome = iota
	// PollSkipped means the reading was not written: a history reading
	// within HistoryGap (inclusive on both sides) of an already-stored
	// reading, or of a history reading from the same StorePoll call
	// already accepted earlier in it; or a current reading that shares
	// an already-stored reading's exact timestamp.
	PollSkipped
	// PollInvalid means the reading was never considered for storage: it
	// failed validation, or (in practice, never, since it needs the
	// system's random source to fail) could not be sealed. Err holds why.
	PollInvalid
)

// ReadingResult is one reading's own outcome from a StorePoll call.
type ReadingResult struct {
	Outcome PollOutcome
	// Err is set only when Outcome is PollInvalid.
	Err error
}

// PollResult is the outcome of one StorePoll call. History has exactly one
// ReadingResult per entry of the history slice StorePoll was given, in the
// same order. Current is nil unless a current reading was passed in, in
// which case it holds that reading's own outcome. PollResult is meaningful
// only when StorePoll's own error is nil -- see StorePoll.
type PollResult struct {
	History []ReadingResult
	Current *ReadingResult
}

// validateReading refuses a reading that cannot be a real measurement.
// StorePoll calls it on every reading before anything else, so an invalid
// history reading is refused even when a near-duplicate would otherwise
// have skipped it.
func validateReading(r cgm.Reading) error {
	if r.Time.IsZero() {
		return fmt.Errorf("%w: zero Time", ErrInvalidReading)
	}
	if r.MgDl <= 0 {
		return fmt.Errorf("%w: non-positive MgDl value %d", ErrInvalidReading, r.MgDl)
	}
	return nil
}

// preparedRow is one reading that passed validation and sealing, ready to
// write.
type preparedRow struct {
	ts     int64
	source string
	sealed []byte
}

// prepareRow validates and seals r. ok is false exactly when r cannot be
// stored, in which case result is the ReadingResult to report for it as
// is; ok is true exactly when row is ready to write.
func (s *Store) prepareRow(r cgm.Reading) (row preparedRow, result ReadingResult, ok bool) {
	if err := validateReading(r); err != nil {
		return preparedRow{}, ReadingResult{Outcome: PollInvalid, Err: err}, false
	}
	ts := r.Time.UTC().Unix()
	sealed, err := sealWithAEAD(s.cipher, aadForTimestamp(ts), encodeValue(r.MgDl, r.Trend))
	if err != nil {
		return preparedRow{}, ReadingResult{
			Outcome: PollInvalid,
			Err:     fmt.Errorf("store: seal reading at %d: %w", ts, err),
		}, false
	}
	return preparedRow{ts: ts, source: r.Source, sealed: sealed}, ReadingResult{}, true
}

// StorePoll stores one poll cycle's history readings and its current
// reading, if any, in a single call.
//
// Every reading is validated and sealed in memory first, so one invalid
// reading is reported for itself, through its own ReadingResult, and never
// affects any other reading -- the current reading above all. Only after
// that does StorePoll touch the database, and it touches it exactly
// twice: one query to decide every history reading's near-duplicate
// question, covering the whole batch's time window in one round trip
// instead of one per reading, and one transaction that writes every
// accepted row and commits once.
//
// A history reading is skipped as a near-duplicate when it is within
// HistoryGap (inclusive on both sides) of an already-stored reading, or of
// a history reading from this same call already accepted earlier in it --
// earlier in the order history is given in, which is the order LibreLinkUp
// sent the readings. history is decided in full, in that order, before
// current is considered.
//
// The current reading ignores HistoryGap entirely and is skipped only if
// a reading already stored shares its exact timestamp.
//
// StorePoll returns a non-nil error only when the write itself failed --
// never for an invalid reading, which is reported through PollResult
// instead. When it returns an error, PollResult is the zero value and
// nothing from this call was stored: the next call's own history refetch
// heals the gap, exactly as an ordinary process crash mid-cycle already
// does.
func (s *Store) StorePoll(ctx context.Context, history []cgm.Reading, current *cgm.Reading) (PollResult, error) {
	result := PollResult{History: make([]ReadingResult, len(history))}

	type pending struct {
		idx int
		row preparedRow
	}
	var validHistory []pending
	var minTs, maxTs int64
	haveWindow := false

	for i, r := range history {
		row, outcome, ok := s.prepareRow(r)
		if !ok {
			result.History[i] = outcome
			continue
		}
		validHistory = append(validHistory, pending{idx: i, row: row})
		if !haveWindow || row.ts < minTs {
			minTs = row.ts
		}
		if !haveWindow || row.ts > maxTs {
			maxTs = row.ts
		}
		haveWindow = true
	}

	var currentRow preparedRow
	haveCurrentRow := false
	if current != nil {
		row, outcome, ok := s.prepareRow(*current)
		if !ok {
			result.Current = &outcome
		} else {
			currentRow = row
			haveCurrentRow = true
		}
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PollResult{}, fmt.Errorf("store: begin poll transaction: %w", err)
	}
	// A deferred Rollback after a successful Commit is a documented no-op
	// (it reports sql.ErrTxDone, which nothing here needs); this only
	// matters on an early return, where it releases the transaction.
	defer tx.Rollback()

	gapSeconds := int64(HistoryGap / time.Second)
	seen := make([]int64, 0, len(validHistory))
	if haveWindow {
		rows, err := tx.QueryContext(ctx,
			"SELECT ts FROM readings WHERE ts >= ? AND ts <= ?",
			minTs-gapSeconds, maxTs+gapSeconds,
		)
		if err != nil {
			return PollResult{}, fmt.Errorf("store: check history gap for %d..%d: %w", minTs, maxTs, err)
		}
		for rows.Next() {
			var ts int64
			if err := rows.Scan(&ts); err != nil {
				rows.Close()
				return PollResult{}, fmt.Errorf("store: scan history gap row: %w", err)
			}
			seen = append(seen, ts)
		}
		scanErr := rows.Err()
		rows.Close()
		if scanErr != nil {
			return PollResult{}, fmt.Errorf("store: history gap rows: %w", scanErr)
		}
	}

	for _, p := range validHistory {
		if nearAny(p.row.ts, seen, gapSeconds) {
			result.History[p.idx] = ReadingResult{Outcome: PollSkipped}
			continue
		}
		inserted, err := insertRow(ctx, tx, p.row)
		if err != nil {
			return PollResult{}, fmt.Errorf("store: insert history reading at %d: %w", p.row.ts, err)
		}
		if inserted {
			seen = append(seen, p.row.ts)
			result.History[p.idx] = ReadingResult{Outcome: PollStored}
		} else {
			// Unreachable in practice: an exact-timestamp match is
			// within any positive gap, so the gap check above already
			// catches it. Kept only as the same defensive fallback a
			// direct INSERT ... ON CONFLICT DO NOTHING always needs.
			result.History[p.idx] = ReadingResult{Outcome: PollSkipped}
		}
	}

	if haveCurrentRow {
		inserted, err := insertRow(ctx, tx, currentRow)
		if err != nil {
			return PollResult{}, fmt.Errorf("store: insert current reading at %d: %w", currentRow.ts, err)
		}
		outcome := PollSkipped
		if inserted {
			outcome = PollStored
		}
		result.Current = &ReadingResult{Outcome: outcome}
	}

	if err := tx.Commit(); err != nil {
		return PollResult{}, fmt.Errorf("store: commit poll: %w", err)
	}
	return result, nil
}

// nearAny reports whether ts is within gapSeconds (inclusive on both
// sides) of any timestamp in seen.
func nearAny(ts int64, seen []int64, gapSeconds int64) bool {
	for _, other := range seen {
		d := ts - other
		if d < 0 {
			d = -d
		}
		if d <= gapSeconds {
			return true
		}
	}
	return false
}

// insertRow inserts row into readings within tx, doing nothing if a row
// with the same timestamp already exists.
func insertRow(ctx context.Context, tx *sql.Tx, row preparedRow) (bool, error) {
	res, err := tx.ExecContext(ctx,
		"INSERT INTO readings (ts, source, sealed) VALUES (?, ?, ?) ON CONFLICT(ts) DO NOTHING",
		row.ts, row.source, row.sealed,
	)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// RangeQuery selects a window of stored readings.
type RangeQuery struct {
	// After is the inclusive lower bound. The zero Time means no lower
	// bound.
	After time.Time
	// Before is the upper bound. The zero Time means no upper bound.
	Before time.Time
	// BeforeInclusive makes Before an inclusive bound instead of the
	// default exclusive one.
	BeforeInclusive bool
	// Limit caps the number of rows returned. Zero or negative means no
	// cap.
	Limit int
}

// Range returns the readings matching q, newest first. Only the rows
// actually returned are decrypted.
func (s *Store) Range(ctx context.Context, q RangeQuery) ([]cgm.Reading, error) {
	var clauses []string
	var args []any

	if !q.After.IsZero() {
		clauses = append(clauses, "ts >= ?")
		args = append(args, q.After.UTC().Unix())
	}
	if !q.Before.IsZero() {
		op := "<"
		if q.BeforeInclusive {
			op = "<="
		}
		clauses = append(clauses, "ts "+op+" ?")
		args = append(args, q.Before.UTC().Unix())
	}

	query := "SELECT ts, source, sealed FROM readings"
	if len(clauses) > 0 {
		query += " WHERE " + strings.Join(clauses, " AND ")
	}
	query += " ORDER BY ts DESC"
	if q.Limit > 0 {
		query += " LIMIT ?"
		args = append(args, q.Limit)
	}

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("store: range query: %w", err)
	}
	defer rows.Close()

	var out []cgm.Reading
	for rows.Next() {
		var ts int64
		var source string
		var sealed []byte
		if err := rows.Scan(&ts, &source, &sealed); err != nil {
			return nil, fmt.Errorf("store: scan range row: %w", err)
		}
		plaintext, err := openWithAEAD(s.cipher, aadForTimestamp(ts), sealed)
		if err != nil {
			return nil, fmt.Errorf("store: decrypt reading at %d: %w", ts, err)
		}
		mgDl, trend, err := decodeValue(plaintext)
		if err != nil {
			return nil, fmt.Errorf("store: decode reading at %d: %w", ts, err)
		}
		out = append(out, cgm.Reading{
			Time:   time.Unix(ts, 0).UTC(),
			MgDl:   mgDl,
			Trend:  trend,
			Source: source,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: range rows: %w", err)
	}
	return out, nil
}

// Prune deletes every reading older than retention, measured back from now,
// and reports how many rows were removed. A reading exactly retention old
// is kept; only strictly older rows are removed.
func (s *Store) Prune(ctx context.Context, now time.Time, retention time.Duration) (removed int64, err error) {
	cutoff := now.UTC().Add(-retention).Unix()
	res, err := s.db.ExecContext(ctx, "DELETE FROM readings WHERE ts < ?", cutoff)
	if err != nil {
		return 0, fmt.Errorf("store: prune before %d: %w", cutoff, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("store: rows affected for prune: %w", err)
	}
	return n, nil
}
