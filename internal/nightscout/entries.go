package nightscout

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// defaultEntryCount is how many entries a request gets when it omits
// "count", matching Nightscout's own default.
const defaultEntryCount = 10

// entry is one glucose reading in the shape Nightscout's entries API
// returns, and the shape follower apps such as xDrip4iOS parse "sgv" and
// "date" out of.
type entry struct {
	ID         string `json:"_id"`
	Type       string `json:"type"`
	SGV        int    `json:"sgv"`
	Date       int64  `json:"date"`
	DateString string `json:"dateString"`
	Direction  string `json:"direction"`
	Device     string `json:"device"`
}

// entryOf converts a stored reading into its Nightscout entry shape. _id is
// derived from the reading's timestamp, which the store's schema enforces
// as unique, so it is stable for a given reading across requests.
func entryOf(r cgm.Reading) entry {
	ts := r.Time.UTC()
	return entry{
		ID:         entryID(ts),
		Type:       "sgv",
		SGV:        r.MgDl,
		Date:       ts.UnixMilli(),
		DateString: ts.Format("2006-01-02T15:04:05.000Z"),
		Direction:  r.Trend.String(),
		Device:     r.Source,
	}
}

// entryID builds a 24-character hex id, the length of a Nightscout/MongoDB
// ObjectId, from a reading's timestamp. Follower apps only read it back
// opaquely; nothing here decodes it.
func entryID(ts time.Time) string {
	return fmt.Sprintf("%024x", ts.Unix())
}

// dateFindKey matches a find[date][$op] query parameter's operator name,
// so an operator this handler does not implement can be told apart from
// one it does, rather than silently dropped.
var dateFindKey = regexp.MustCompile(`^find\[date\]\[\$(\w+)\]$`)

// supportedDateOperators is every find[date][$...] operator handleEntries
// understands. Anything else under find[date] is a 400, never a bound
// that gets ignored.
var supportedDateOperators = map[string]bool{"gte": true, "gt": true, "lt": true, "lte": true}

// checkDateOperators reports an error naming the first find[date][$...]
// query parameter in q whose operator handleEntries does not implement.
func checkDateOperators(q url.Values) error {
	for key := range q {
		m := dateFindKey.FindStringSubmatch(key)
		if m == nil || supportedDateOperators[m[1]] {
			continue
		}
		return fmt.Errorf("nightscout: unsupported query parameter %s", key)
	}
	return nil
}

// handleEntries serves /api/v1/entries.json and /api/v1/entries/sgv.json.
// The two are identical here because every reading the store holds is
// already an "sgv" entry.
func (h *handler) handleEntries(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()

	count := defaultEntryCount
	if raw := q.Get("count"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 {
			http.Error(w, "nightscout: count must be a non-negative integer", http.StatusBadRequest)
			return
		}
		count = n
	}
	if count == 0 {
		// Nothing asked for, so nothing to read: nothing is decrypted and
		// the store is never queried.
		writeJSON(w, r, []entry{})
		return
	}

	if err := checkDateOperators(q); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	rq, err := entriesRangeQuery(q, count)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	readings, err := h.readings.Range(r.Context(), rq)
	if err != nil {
		http.Error(w, "nightscout: read readings: "+err.Error(), http.StatusInternalServerError)
		return
	}

	entries := make([]entry, 0, len(readings))
	for _, rd := range readings {
		entries = append(entries, entryOf(rd))
	}
	writeJSON(w, r, entries)
}

// entriesRangeQuery builds the exact store.RangeQuery for q's find[date]
// bounds and count: every millisecond bound is converted to the whole
// second the store filters by (a reading at second t has date t*1000), so
// the store itself returns exactly the matching rows, newest first,
// capped at count, with nothing left to filter or over-fetch afterward.
func entriesRangeQuery(q url.Values, count int) (store.RangeQuery, error) {
	rq := store.RangeQuery{Limit: count}

	gte, hasGte, err := parseMillisParam(q, "find[date][$gte]")
	if err != nil {
		return store.RangeQuery{}, err
	}
	gt, hasGt, err := parseMillisParam(q, "find[date][$gt]")
	if err != nil {
		return store.RangeQuery{}, err
	}
	lt, hasLt, err := parseMillisParam(q, "find[date][$lt]")
	if err != nil {
		return store.RangeQuery{}, err
	}
	lte, hasLte, err := parseMillisParam(q, "find[date][$lte]")
	if err != nil {
		return store.RangeQuery{}, err
	}

	// The lower bound is the tightest (largest) second that satisfies
	// every $gte/$gt the caller sent.
	var afterSecond int64
	var hasAfter bool
	if hasGte {
		afterSecond, hasAfter = tighterLowerBound(afterSecond, ceilDiv(gte, 1000), hasAfter)
	}
	if hasGt {
		afterSecond, hasAfter = tighterLowerBound(afterSecond, floorDiv(gt, 1000)+1, hasAfter)
	}
	if hasAfter {
		rq.After = time.Unix(afterSecond, 0).UTC()
	}

	// The upper bound is the tightest (smallest) second that satisfies
	// every $lt/$lte the caller sent. It is always applied inclusively:
	// the exclusivity $lt needs is already folded into its own converted
	// second (see below), so the store's own Before field never needs to
	// be exclusive here.
	var beforeSecond int64
	var hasBefore bool
	if hasLt {
		beforeSecond, hasBefore = tighterUpperBound(beforeSecond, ceilDiv(lt, 1000)-1, hasBefore)
	}
	if hasLte {
		beforeSecond, hasBefore = tighterUpperBound(beforeSecond, floorDiv(lte, 1000), hasBefore)
	}
	if hasBefore {
		rq.Before = time.Unix(beforeSecond, 0).UTC()
		rq.BeforeInclusive = true
	}

	return rq, nil
}

// tighterLowerBound folds a newly computed inclusive lower-bound second
// into the running bound, keeping whichever is larger (stricter) so every
// bound the caller sent is honoured at once.
func tighterLowerBound(current, next int64, hasCurrent bool) (int64, bool) {
	if !hasCurrent || next > current {
		return next, true
	}
	return current, true
}

// tighterUpperBound folds a newly computed inclusive upper-bound second
// into the running bound, keeping whichever is smaller (stricter).
func tighterUpperBound(current, next int64, hasCurrent bool) (int64, bool) {
	if !hasCurrent || next < current {
		return next, true
	}
	return current, true
}

// floorDiv and ceilDiv are integer floor and ceiling division, correct for
// a negative dividend (Go's own "/" truncates toward zero, which is not
// floor division below zero). b is always positive in this package's own
// use (b == 1000), but the sign handling below is general.
func floorDiv(a, b int64) int64 {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

func ceilDiv(a, b int64) int64 {
	return -floorDiv(-a, b)
}

// handleCurrent serves /api/v1/entries/current.json: the single newest
// reading, in the same entry shape as the other entries endpoints, or an
// empty array if the store holds nothing yet.
func (h *handler) handleCurrent(w http.ResponseWriter, r *http.Request) {
	readings, err := h.readings.Range(r.Context(), store.RangeQuery{Limit: 1})
	if err != nil {
		http.Error(w, "nightscout: read readings: "+err.Error(), http.StatusInternalServerError)
		return
	}

	entries := make([]entry, 0, len(readings))
	for _, rd := range readings {
		entries = append(entries, entryOf(rd))
	}
	writeJSON(w, r, entries)
}

// parseMillisParam parses q's value for key as a millisecond Unix
// timestamp. present is false, with no error, when the parameter is
// absent.
func parseMillisParam(q url.Values, key string) (ms int64, present bool, err error) {
	raw := q.Get(key)
	if raw == "" {
		return 0, false, nil
	}
	ms, err = strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, false, fmt.Errorf("nightscout: %s must be an integer millisecond timestamp", key)
	}
	return ms, true, nil
}

// writeJSON writes v as a JSON response body with the standard Nightscout
// content type, gzip-encoded when r's combined Accept-Encoding accepts
// gzip and the encoded body is large enough for compression to be worth
// its own container overhead (see writeMaybeGzipped in compress.go). v is
// marshaled to bytes before anything is written to w, so a marshal
// failure becomes a clean 500 instead of a response already partly on
// the wire, the way json.NewEncoder writing directly to w once did. The
// trailing newline json.NewEncoder.Encode always appends is added back
// here explicitly, so switching away from it changes nothing about the
// bytes a client that never asks for gzip receives.
func writeJSON(w http.ResponseWriter, r *http.Request, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		http.Error(w, "nightscout: encode response: "+err.Error(), http.StatusInternalServerError)
		return
	}
	body = append(body, '\n')
	w.Header().Set("Content-Type", "application/json")
	writeMaybeGzipped(w, r, body)
}
