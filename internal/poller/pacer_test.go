package poller

import (
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

// TestPacerObserve checks the wait after a fetch: a new reading is followed
// by a fetch about an Interval later however young it was when first seen, a
// repeat of it is retried soon while it could still be replaced, and a
// reading that has outlived its minute is asked about again almost at once.
func TestPacerObserve(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	tests := []struct {
		name      string
		firstAge  time.Duration
		repeatAt  time.Duration // how long after the first fetch the repeat happens
		wantFirst time.Duration
		wantRetry time.Duration
	}{
		{"seen young", 5 * time.Second, 55 * time.Second, Interval - fetchLead, uploadRetry},
		{"seen at a fast phone's usual age", 20 * time.Second, 55 * time.Second, Interval - fetchLead, uploadRetry},
		{"seen at a slow phone's usual age", 45 * time.Second, 55 * time.Second, Interval - fetchLead, uploadRetry},
		{"seen after it outlived its minute", 135 * time.Second, minFetchGap, minFetchGap, uploadRetry},
		{"repeat once nothing newer is plausible", 20 * time.Second, 200 * time.Second, Interval - fetchLead, Interval},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var p pacer
			reading := &cgm.Reading{Time: start, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}

			wait, fresh := p.observe(start.Add(tt.firstAge), reading)
			if !fresh || wait != tt.wantFirst {
				t.Fatalf("first sight at age %s: wait %s fresh %v, want wait %s fresh true", tt.firstAge, wait, fresh, tt.wantFirst)
			}
			wait, fresh = p.observe(start.Add(tt.firstAge+tt.repeatAt), reading)
			if fresh || wait != tt.wantRetry {
				t.Errorf("repeat %s later: wait %s fresh %v, want wait %s fresh false", tt.repeatAt, wait, fresh, tt.wantRetry)
			}
		})
	}
}
