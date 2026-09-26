package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// TestInsertHistoryGap checks the near-duplicate gap rule for history
// readings at each side of the HistoryGap boundary: an offset within the
// gap (inclusive) from an already-stored reading is dropped, and one
// strictly outside it is stored.
func TestInsertHistoryGap(t *testing.T) {
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

			inserted, err := s.InsertHistory(ctx, cgm.Reading{
				Time: anchor, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic",
			})
			if err != nil {
				t.Fatalf("seed InsertHistory: %v", err)
			}
			if !inserted {
				t.Fatal("seed reading was not stored")
			}

			gotInserted, err := s.InsertHistory(ctx, cgm.Reading{
				Time: anchor.Add(c.offset), MgDl: 101, Trend: cgm.TrendFlat, Source: "synthetic",
			})
			if err != nil {
				t.Fatalf("InsertHistory: %v", err)
			}
			if gotInserted != c.wantStored {
				t.Errorf("InsertHistory at offset %s: inserted = %v, want %v", c.offset, gotInserted, c.wantStored)
			}
		})
	}
}

// TestInsertCurrentIgnoresGapButDedupsExactTimestamp checks that
// InsertCurrent, unlike InsertHistory, is never skipped merely for being
// close to an existing row -- only an exact timestamp match is a no-op.
func TestInsertCurrentIgnoresGapButDedupsExactTimestamp(t *testing.T) {
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

			inserted, err := s.InsertCurrent(ctx, cgm.Reading{
				Time: anchor, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic",
			})
			if err != nil {
				t.Fatalf("seed InsertCurrent: %v", err)
			}
			if !inserted {
				t.Fatal("seed reading was not stored")
			}

			gotInserted, err := s.InsertCurrent(ctx, cgm.Reading{
				Time: anchor.Add(c.offset), MgDl: 101, Trend: cgm.TrendFlat, Source: "synthetic",
			})
			if err != nil {
				t.Fatalf("InsertCurrent: %v", err)
			}
			if gotInserted != c.wantStored {
				t.Errorf("InsertCurrent at offset %s: inserted = %v, want %v", c.offset, gotInserted, c.wantStored)
			}
		})
	}
}

// TestInsertRejectsInvalidReading checks that neither insert path can put a
// reading with a zero Time or a non-positive MgDl into the store: both
// return store.ErrInvalidReading and leave the table empty.
func TestInsertRejectsInvalidReading(t *testing.T) {
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
		t.Run("InsertCurrent/"+c.name, func(t *testing.T) {
			ctx := context.Background()
			s, _ := openTemp(t, ctx)

			inserted, err := s.InsertCurrent(ctx, c.r)
			if err == nil {
				t.Fatal("InsertCurrent accepted an invalid reading, want an error")
			}
			if !errors.Is(err, store.ErrInvalidReading) {
				t.Errorf("error = %v, want it to wrap store.ErrInvalidReading", err)
			}
			if inserted {
				t.Error("InsertCurrent reported inserted=true for a rejected reading")
			}
			assertTableEmpty(t, ctx, s)
		})

		t.Run("InsertHistory/"+c.name, func(t *testing.T) {
			ctx := context.Background()
			s, _ := openTemp(t, ctx)

			inserted, err := s.InsertHistory(ctx, c.r)
			if err == nil {
				t.Fatal("InsertHistory accepted an invalid reading, want an error")
			}
			if !errors.Is(err, store.ErrInvalidReading) {
				t.Errorf("error = %v, want it to wrap store.ErrInvalidReading", err)
			}
			if inserted {
				t.Error("InsertHistory reported inserted=true for a rejected reading")
			}
			assertTableEmpty(t, ctx, s)
		})
	}

	// An invalid history reading next to a stored one must still be refused,
	// never mistaken for a near-duplicate and skipped without an error.
	t.Run("InsertHistory/MgDl 0 within the gap of a stored reading", func(t *testing.T) {
		ctx := context.Background()
		s, _ := openTemp(t, ctx)
		anchor := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

		if _, err := s.InsertCurrent(ctx, cgm.Reading{
			Time: anchor, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic",
		}); err != nil {
			t.Fatalf("seed InsertCurrent: %v", err)
		}

		inserted, err := s.InsertHistory(ctx, cgm.Reading{
			Time: anchor.Add(time.Minute), MgDl: 0, Trend: cgm.TrendFlat, Source: "synthetic",
		})
		if !errors.Is(err, store.ErrInvalidReading) {
			t.Fatalf("error = %v, want it to wrap store.ErrInvalidReading", err)
		}
		if inserted {
			t.Error("InsertHistory reported inserted=true for a rejected reading")
		}
	})
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
