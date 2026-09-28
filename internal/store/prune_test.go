package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// TestPruneBoundary checks the retention cutoff on both sides: a reading
// exactly `retention` old is kept (only readings strictly older than that
// are removed), one just past the cutoff is removed, and one well inside
// the window is untouched.
func TestPruneBoundary(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s, _ := openTemp(t, ctx)

	now := time.Date(2026, 7, 15, 0, 0, 0, 0, time.UTC)
	const retention = 15 * 24 * time.Hour

	readings := map[string]cgm.Reading{
		"well within retention": {Time: now.Add(-1 * time.Hour), MgDl: 1, Trend: cgm.TrendFlat, Source: "synthetic"},
		"exactly at the cutoff, kept": {
			Time: now.Add(-retention), MgDl: 2, Trend: cgm.TrendFlat, Source: "synthetic",
		},
		"one second past the cutoff, removed": {
			Time: now.Add(-retention - time.Second), MgDl: 3, Trend: cgm.TrendFlat, Source: "synthetic",
		},
		"well past retention, removed": {
			Time: now.Add(-30 * 24 * time.Hour), MgDl: 4, Trend: cgm.TrendFlat, Source: "synthetic",
		},
	}
	for name, r := range readings {
		if _, err := s.StorePoll(ctx, nil, &r); err != nil {
			t.Fatalf("seed %q: %v", name, err)
		}
	}

	removed, err := s.Prune(ctx, now, retention)
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	if removed != 2 {
		t.Errorf("Prune removed %d rows, want 2", removed)
	}

	remaining, err := s.Range(ctx, store.RangeQuery{})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	gotMgDl := map[int]bool{}
	for _, r := range remaining {
		gotMgDl[r.MgDl] = true
	}
	if len(remaining) != 2 || !gotMgDl[1] || !gotMgDl[2] {
		t.Errorf("remaining readings = %v, want exactly MgDl 1 and 2 to survive", mgDlsOf(remaining))
	}
}

// TestPruneDefaultRetentionConstant pins DefaultRetention to the documented
// 15 days, since callers wire it in as the default and a silent change to
// it would change retention behaviour with no code review catching it.
func TestPruneDefaultRetentionConstant(t *testing.T) {
	t.Parallel()
	want := 15 * 24 * time.Hour
	if store.DefaultRetention != want {
		t.Errorf("DefaultRetention = %v, want %v", store.DefaultRetention, want)
	}
}
