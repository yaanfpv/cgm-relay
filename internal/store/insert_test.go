package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// TestStorePollHistoryGapAgainstStoredReading checks the near-duplicate gap
// rule for a history reading against a reading already stored before the
// StorePoll call: an offset within HistoryGap (inclusive) of the stored
// reading is skipped, and one strictly outside it is stored.
func TestStorePollHistoryGapAgainstStoredReading(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name       string
		offset     time.Duration
		wantStored bool
	}{
		{"0s: exact duplicate", 0, false},
		{"149s: inside the gap", 149 * time.Second, false},
		{"150s: at the gap boundary, inclusive", 150 * time.Second, false},
		{"151s: just outside the gap", 151 * time.Second, true},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ctx := context.Background()
			s, _ := openTemp(t, ctx)
			anchor := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

			seed := cgm.Reading{Time: anchor, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}
			seedResult, err := s.StorePoll(ctx, []cgm.Reading{seed}, nil)
			if err != nil {
				t.Fatalf("seed StorePoll: %v", err)
			}
			if seedResult.History[0].Outcome != store.PollStored {
				t.Fatalf("seed outcome = %+v, want PollStored", seedResult.History[0])
			}

			candidate := cgm.Reading{Time: anchor.Add(c.offset), MgDl: 101, Trend: cgm.TrendFlat, Source: "synthetic"}
			result, err := s.StorePoll(ctx, []cgm.Reading{candidate}, nil)
			if err != nil {
				t.Fatalf("StorePoll: %v", err)
			}
			gotStored := result.History[0].Outcome == store.PollStored
			if gotStored != c.wantStored {
				t.Errorf("offset %s: outcome = %+v, want stored=%v", c.offset, result.History[0], c.wantStored)
			}
		})
	}
}

// TestStorePollHistoryGapAgainstSameBatchNeighbor checks the identical gap
// rule when the near-duplicate is not already stored, but is an earlier
// history reading in the very same StorePoll call: a history reading must
// decide the near-duplicate question against a history reading accepted
// earlier in its own batch exactly as it would against one already in the
// store, at every boundary offset.
func TestStorePollHistoryGapAgainstSameBatchNeighbor(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name       string
		offset     time.Duration
		wantStored bool
	}{
		{"0s: exact duplicate", 0, false},
		{"149s: inside the gap", 149 * time.Second, false},
		{"150s: at the gap boundary, inclusive", 150 * time.Second, false},
		{"151s: just outside the gap", 151 * time.Second, true},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ctx := context.Background()
			s, _ := openTemp(t, ctx)
			anchor := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

			anchorReading := cgm.Reading{Time: anchor, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}
			candidate := cgm.Reading{Time: anchor.Add(c.offset), MgDl: 101, Trend: cgm.TrendFlat, Source: "synthetic"}

			result, err := s.StorePoll(ctx, []cgm.Reading{anchorReading, candidate}, nil)
			if err != nil {
				t.Fatalf("StorePoll: %v", err)
			}
			if result.History[0].Outcome != store.PollStored {
				t.Fatalf("anchor outcome = %+v, want PollStored", result.History[0])
			}
			gotStored := result.History[1].Outcome == store.PollStored
			if gotStored != c.wantStored {
				t.Errorf("offset %s: candidate outcome = %+v, want stored=%v", c.offset, result.History[1], c.wantStored)
			}
		})
	}
}

// TestStorePollCurrentIgnoresGapButDedupsExactTimestamp checks that a
// current reading, unlike a history reading, is never skipped merely for
// being close in time to an existing row -- only an exact timestamp match
// is a no-op.
func TestStorePollCurrentIgnoresGapButDedupsExactTimestamp(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name       string
		offset     time.Duration
		wantStored bool
	}{
		{"0s: exact duplicate is a no-op", 0, false},
		{"1s: distinct timestamp, always stored", time.Second, true},
		{"149s: distinct timestamp, always stored", 149 * time.Second, true},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ctx := context.Background()
			s, _ := openTemp(t, ctx)
			anchor := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

			seed := cgm.Reading{Time: anchor, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}
			seedResult, err := s.StorePoll(ctx, nil, &seed)
			if err != nil {
				t.Fatalf("seed StorePoll: %v", err)
			}
			if seedResult.Current == nil || seedResult.Current.Outcome != store.PollStored {
				t.Fatalf("seed outcome = %+v, want PollStored", seedResult.Current)
			}

			candidate := cgm.Reading{Time: anchor.Add(c.offset), MgDl: 101, Trend: cgm.TrendFlat, Source: "synthetic"}
			result, err := s.StorePoll(ctx, nil, &candidate)
			if err != nil {
				t.Fatalf("StorePoll: %v", err)
			}
			gotStored := result.Current != nil && result.Current.Outcome == store.PollStored
			if gotStored != c.wantStored {
				t.Errorf("offset %s: outcome = %+v, want stored=%v", c.offset, result.Current, c.wantStored)
			}
		})
	}
}

// TestStorePollRejectsInvalidReading checks that neither a history reading
// nor a current reading with a zero Time or a non-positive MgDl value is
// ever stored: each is reported with PollInvalid, wrapping
// store.ErrInvalidReading, and leaves the table empty.
func TestStorePollRejectsInvalidReading(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		r    cgm.Reading
	}{
		{
			name: "zero Time",
			r:    cgm.Reading{MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"},
		},
		{
			name: "MgDl 0",
			r: cgm.Reading{
				Time: time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC), MgDl: 0,
				Trend: cgm.TrendFlat, Source: "synthetic",
			},
		},
	}

	for _, c := range cases {
		t.Run("current/"+c.name, func(t *testing.T) {
			ctx := context.Background()
			s, _ := openTemp(t, ctx)

			result, err := s.StorePoll(ctx, nil, &c.r)
			if err != nil {
				t.Fatalf("StorePoll returned an error, want a per-reading PollInvalid outcome instead: %v", err)
			}
			if result.Current == nil || result.Current.Outcome != store.PollInvalid {
				t.Fatalf("current outcome = %+v, want PollInvalid", result.Current)
			}
			if !errors.Is(result.Current.Err, store.ErrInvalidReading) {
				t.Errorf("Err = %v, want it to wrap store.ErrInvalidReading", result.Current.Err)
			}
			assertTableEmpty(t, ctx, s)
		})

		t.Run("history/"+c.name, func(t *testing.T) {
			ctx := context.Background()
			s, _ := openTemp(t, ctx)

			result, err := s.StorePoll(ctx, []cgm.Reading{c.r}, nil)
			if err != nil {
				t.Fatalf("StorePoll returned an error, want a per-reading PollInvalid outcome instead: %v", err)
			}
			if result.History[0].Outcome != store.PollInvalid {
				t.Fatalf("history outcome = %+v, want PollInvalid", result.History[0])
			}
			if !errors.Is(result.History[0].Err, store.ErrInvalidReading) {
				t.Errorf("Err = %v, want it to wrap store.ErrInvalidReading", result.History[0].Err)
			}
			assertTableEmpty(t, ctx, s)
		})
	}

	// An invalid history reading next to a stored one must still be
	// refused, never mistaken for a near-duplicate and skipped without
	// being reported as invalid.
	t.Run("history/MgDl 0 within the gap of a stored reading", func(t *testing.T) {
		ctx := context.Background()
		s, _ := openTemp(t, ctx)
		anchor := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

		seed := cgm.Reading{Time: anchor, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}
		if _, err := s.StorePoll(ctx, nil, &seed); err != nil {
			t.Fatalf("seed StorePoll: %v", err)
		}

		invalid := cgm.Reading{Time: anchor.Add(time.Minute), MgDl: 0, Trend: cgm.TrendFlat, Source: "synthetic"}
		result, err := s.StorePoll(ctx, []cgm.Reading{invalid}, nil)
		if err != nil {
			t.Fatalf("StorePoll: %v", err)
		}
		if result.History[0].Outcome != store.PollInvalid {
			t.Fatalf("outcome = %+v, want PollInvalid", result.History[0])
		}
		if !errors.Is(result.History[0].Err, store.ErrInvalidReading) {
			t.Errorf("Err = %v, want it to wrap store.ErrInvalidReading", result.History[0].Err)
		}
	})
}

// TestStorePollInvalidHistoryPointDoesNotBlockValidCurrent checks the
// central claim behind batching every poll's writes into one call: an
// invalid history reading is reported for itself and never keeps the
// current reading -- or any other history reading -- in the same call
// from being stored normally.
func TestStorePollInvalidHistoryPointDoesNotBlockValidCurrent(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s, _ := openTemp(t, ctx)
	anchor := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

	invalidHistory := cgm.Reading{Time: anchor.Add(-time.Hour), MgDl: 0, Trend: cgm.TrendFlat, Source: "synthetic"}
	validHistory := cgm.Reading{Time: anchor.Add(-30 * time.Minute), MgDl: 90, Trend: cgm.TrendFlat, Source: "synthetic"}
	current := cgm.Reading{Time: anchor, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}

	result, err := s.StorePoll(ctx, []cgm.Reading{invalidHistory, validHistory}, &current)
	if err != nil {
		t.Fatalf("StorePoll: %v", err)
	}

	if result.History[0].Outcome != store.PollInvalid {
		t.Errorf("invalid history outcome = %+v, want PollInvalid", result.History[0])
	}
	if !errors.Is(result.History[0].Err, store.ErrInvalidReading) {
		t.Errorf("invalid history Err = %v, want it to wrap store.ErrInvalidReading", result.History[0].Err)
	}
	if result.History[1].Outcome != store.PollStored {
		t.Errorf("valid history outcome = %+v, want PollStored", result.History[1])
	}
	if result.Current == nil || result.Current.Outcome != store.PollStored {
		t.Fatalf("current outcome = %+v, want PollStored", result.Current)
	}

	rows, err := s.Range(ctx, store.RangeQuery{})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("table has %d rows, want exactly the valid history reading and the current reading (%v)", len(rows), mgDlsOf(rows))
	}
	got := map[int]bool{}
	for _, r := range rows {
		got[r.MgDl] = true
	}
	if !got[90] || !got[100] {
		t.Errorf("stored MgDl values = %v, want exactly {90, 100}", mgDlsOf(rows))
	}
}

func assertTableEmpty(t *testing.T, ctx context.Context, s *store.Store) {
	t.Helper()
	rows, err := s.Range(ctx, store.RangeQuery{})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("table has %d rows after a rejected insert, want 0", len(rows))
	}
}
