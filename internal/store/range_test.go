package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// seedRange stores five readings one minute apart, at minutes 0,1,2,3,4
// past base, each carrying its minute offset plus one as MgDl (MgDl must be
// positive) so a test can identify which rows came back.
func seedRange(t *testing.T, ctx context.Context, s *store.Store, base time.Time) {
	t.Helper()
	for i := 0; i < 5; i++ {
		r := cgm.Reading{
			Time:   base.Add(time.Duration(i) * time.Minute),
			MgDl:   i + 1,
			Trend:  cgm.TrendFlat,
			Source: "synthetic",
		}
		inserted, err := s.InsertCurrent(ctx, r)
		if err != nil {
			t.Fatalf("seed InsertCurrent[%d]: %v", i, err)
		}
		if !inserted {
			t.Fatalf("seed row %d was not stored", i)
		}
	}
}

func TestRangeOrdersNewestFirst(t *testing.T) {
	ctx := context.Background()
	s, _ := openTemp(t, ctx)
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	seedRange(t, ctx, s, base)

	got, err := s.Range(ctx, store.RangeQuery{})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	want := []int{5, 4, 3, 2, 1}
	assertMgDlSequence(t, got, want)
}

func TestRangeLowerBoundInclusive(t *testing.T) {
	ctx := context.Background()
	s, _ := openTemp(t, ctx)
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	seedRange(t, ctx, s, base)

	got, err := s.Range(ctx, store.RangeQuery{After: base.Add(2 * time.Minute)})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	assertMgDlSequence(t, got, []int{5, 4, 3})
}

func TestRangeUpperBoundExclusiveByDefault(t *testing.T) {
	ctx := context.Background()
	s, _ := openTemp(t, ctx)
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	seedRange(t, ctx, s, base)

	got, err := s.Range(ctx, store.RangeQuery{Before: base.Add(2 * time.Minute)})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	assertMgDlSequence(t, got, []int{2, 1})
}

func TestRangeUpperBoundInclusive(t *testing.T) {
	ctx := context.Background()
	s, _ := openTemp(t, ctx)
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	seedRange(t, ctx, s, base)

	got, err := s.Range(ctx, store.RangeQuery{
		Before:          base.Add(2 * time.Minute),
		BeforeInclusive: true,
	})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	assertMgDlSequence(t, got, []int{3, 2, 1})
}

func TestRangeLimit(t *testing.T) {
	ctx := context.Background()
	s, _ := openTemp(t, ctx)
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	seedRange(t, ctx, s, base)

	got, err := s.Range(ctx, store.RangeQuery{Limit: 2})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	assertMgDlSequence(t, got, []int{5, 4})
}

func TestRangeCombinesBoundsAndLimit(t *testing.T) {
	ctx := context.Background()
	s, _ := openTemp(t, ctx)
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	seedRange(t, ctx, s, base)

	got, err := s.Range(ctx, store.RangeQuery{
		After:  base.Add(1 * time.Minute),
		Before: base.Add(4 * time.Minute),
		Limit:  1,
	})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	// The window (after minute 1, before minute 4) covers minutes 1,2,3
	// (MgDl 2,3,4), newest first is minute 3 (MgDl 4), and the limit trims
	// that to just that one row.
	assertMgDlSequence(t, got, []int{4})
}

func assertMgDlSequence(t *testing.T, got []cgm.Reading, want []int) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %d readings, want %d (got=%v)", len(got), len(want), mgDlsOf(got))
	}
	for i, w := range want {
		if got[i].MgDl != w {
			t.Errorf("row %d: MgDl = %d, want %d (full sequence got=%v, want=%v)", i, got[i].MgDl, w, mgDlsOf(got), want)
		}
	}
}

func mgDlsOf(rs []cgm.Reading) []int {
	out := make([]int, len(rs))
	for i, r := range rs {
		out[i] = r.MgDl
	}
	return out
}
