package nightscout_test

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// reading builds a synthetic reading at t with mgDl as its value. Tests use
// it to seed a fakeStore without repeating the full cgm.Reading literal
// each time.
func reading(t time.Time, mgDl int) cgm.Reading {
	return cgm.Reading{Time: t, MgDl: mgDl, Trend: cgm.TrendFlat, Source: "synthetic"}
}

// fakeStore is a ReadingRange that filters an in-memory slice the same way
// store.Store.Range documents its own behaviour: newest first, After
// inclusive, Before exclusive unless BeforeInclusive, Limit capping the
// result. Handler tests run against this instead of a real SQLite store so
// they stay fast and never touch a filesystem.
type fakeStore struct {
	readings []cgm.Reading
	err      error

	// lastQuery records the RangeQuery the handler most recently issued,
	// and rangeCalls how many times it issued one at all, so a test can
	// check what it asked the store for, not just what came back -- in
	// particular, that it asks for no more rows than it can use, and that
	// it does not query the store at all for a request that needs no rows
	// (see TestEntriesLimitsStoreQuery).
	lastQuery  store.RangeQuery
	rangeCalls int
}

// errFakeStore is returned by a fakeStore configured to fail, so handler
// tests can check the 500 path without a real store error.
var errFakeStore = errors.New("fakeStore: simulated failure")

func (f *fakeStore) Range(ctx context.Context, q store.RangeQuery) ([]cgm.Reading, error) {
	f.lastQuery = q
	f.rangeCalls++
	if f.err != nil {
		return nil, f.err
	}

	sorted := append([]cgm.Reading(nil), f.readings...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Time.After(sorted[j].Time) })

	var out []cgm.Reading
	for _, r := range sorted {
		ts := r.Time.UTC().Unix()
		if !q.After.IsZero() && ts < q.After.UTC().Unix() {
			continue
		}
		if !q.Before.IsZero() {
			before := q.Before.UTC().Unix()
			if q.BeforeInclusive {
				if ts > before {
					continue
				}
			} else if ts >= before {
				continue
			}
		}
		out = append(out, r)
		if q.Limit > 0 && len(out) == q.Limit {
			break
		}
	}
	return out, nil
}
