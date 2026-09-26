package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

// HistoryGap is how close, in time, a history reading must be to an
// already-stored reading before InsertHistory treats it as a near-duplicate
// and skips it.
const HistoryGap = 150 * time.Second

// DefaultRetention is how long a reading is kept before Prune removes it.
const DefaultRetention = 15 * 24 * time.Hour

// ErrInvalidReading is returned by InsertCurrent and InsertHistory when the
// reading has a zero Time or a non-positive MgDl value. Nothing is stored
// in that case.
var ErrInvalidReading = errors.New("store: invalid reading")

// InsertCurrent stores r as the account's current reading. It is a no-op,
// reporting inserted=false, if a reading with r's exact timestamp is
// already stored; unlike InsertHistory, it ignores HistoryGap entirely.
func (s *Store) InsertCurrent(ctx context.Context, r cgm.Reading) (inserted bool, err error) {
	if err := validateReading(r); err != nil {
		return false, err
	}
	return s.insertRow(ctx, r)
}

// InsertHistory stores r unless a reading already stored is within
// HistoryGap (inclusive) of r's timestamp, in which case it is a near-
// duplicate and InsertHistory is a no-op, reporting inserted=false.
func (s *Store) InsertHistory(ctx context.Context, r cgm.Reading) (inserted bool, err error) {
	if err := validateReading(r); err != nil {
		return false, err
	}
	ts := r.Time.UTC().Unix()
	gapSeconds := int64(HistoryGap / time.Second)

	var nearby int
	err = s.db.QueryRowContext(ctx,
		"SELECT COUNT(1) FROM readings WHERE ts >= ? AND ts <= ?",
		ts-gapSeconds, ts+gapSeconds,
	).Scan(&nearby)
	if err != nil {
		return false, fmt.Errorf("store: check history gap at %d: %w", ts, err)
	}
	if nearby > 0 {
		return false, nil
	}
	return s.insertRow(ctx, r)
}

// validateReading refuses a reading that cannot be a real measurement. Both
// insert paths call it before anything else, so an invalid history reading
// is refused even when a near-duplicate would otherwise have skipped it.
func validateReading(r cgm.Reading) error {
	if r.Time.IsZero() {
		return fmt.Errorf("%w: zero Time", ErrInvalidReading)
	}
	if r.MgDl <= 0 {
		return fmt.Errorf("%w: non-positive MgDl value %d", ErrInvalidReading, r.MgDl)
	}
	return nil
}

// insertRow seals r's value and trend and inserts the row, doing nothing if
// a row with the same timestamp already exists.
func (s *Store) insertRow(ctx context.Context, r cgm.Reading) (bool, error) {
	ts := r.Time.UTC().Unix()
	sealed, err := sealBytes(s.key, aadForTimestamp(ts), encodeValue(r.MgDl, r.Trend))
	if err != nil {
		return false, fmt.Errorf("store: seal reading at %d: %w", ts, err)
	}

	res, err := s.db.ExecContext(ctx,
		"INSERT INTO readings (ts, source, sealed) VALUES (?, ?, ?) ON CONFLICT(ts) DO NOTHING",
		ts, r.Source, sealed,
	)
	if err != nil {
		return false, fmt.Errorf("store: insert reading at %d: %w", ts, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("store: rows affected for insert at %d: %w", ts, err)
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
		plaintext, err := openBytes(s.key, aadForTimestamp(ts), sealed)
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
