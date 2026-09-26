package poller_test

import (
	"context"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunStoresOneCurrentReadingPerTick drives ten ticks past Run's
// initial, immediate fetch and checks that InsertCurrent was called
// exactly once per tick, each with a distinct reading, so neither a missed
// tick nor a duplicate store can hide in the count.
func TestRunStoresOneCurrentReadingPerTick(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)
	src := &fakeSource{respond: func(call int) sourceResponse {
		return sourceResponse{current: &cgm.Reading{
			Time: start.Add(time.Duration(call) * time.Minute),
			MgDl: 100 + call, Trend: cgm.TrendFlat, Source: "synthetic",
		}}
	}}
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	const ticks = 10
	for i := 0; i < ticks; i++ {
		clock.tick(poller.Interval)
	}
	// The last tick only releases Run to run its final fetchAndStore; wait
	// for the timer that follows it, proving that call has completed,
	// before reading the store or cancelling.
	clock.waitForNextWait()

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}

	got := st.currentTimes()
	const wantCalls = ticks + 1 // the immediate fetch, plus one per tick
	if len(got) != wantCalls {
		t.Fatalf("InsertCurrent called %d times, want %d", len(got), wantCalls)
	}
	seen := map[time.Time]bool{}
	for _, ts := range got {
		if seen[ts] {
			t.Errorf("reading at %s was stored more than once", ts)
		}
		seen[ts] = true
	}
}

// TestRunRoutesHistoryAndSkipsNilCurrent checks that history readings only
// ever go through InsertHistory, that a nil current reading stores nothing
// and is not treated as an error, and that a later tick with a real
// current reading still stores normally.
func TestRunRoutesHistoryAndSkipsNilCurrent(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)

	hist := []cgm.Reading{
		{Time: start.Add(-2 * time.Minute), MgDl: 90, Trend: cgm.TrendFlat, Source: "synthetic"},
		{Time: start.Add(-1 * time.Minute), MgDl: 95, Trend: cgm.TrendFlat, Source: "synthetic"},
	}
	nextReading := start.Add(poller.Interval)
	src := scriptedSource([]sourceResponse{
		{current: nil, history: hist},
		{current: &cgm.Reading{Time: nextReading, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	clock.tick(poller.Interval)
	// That tick only releases Run to run the second fetch; wait for the
	// timer that follows it, proving that call has completed.
	clock.waitForNextWait()

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}

	if got := st.historyTimes(); len(got) != 2 {
		t.Fatalf("InsertHistory called %d times, want 2 (from %v)", len(got), got)
	}
	if got := st.currentTimes(); len(got) != 1 || got[0] != nextReading {
		t.Fatalf("InsertCurrent calls = %v, want exactly one at %s", got, nextReading)
	}
	if status := p.Status(); status.LastError != "" {
		t.Errorf("Status().LastError = %q after a nil current reading, want empty (a nil current is not an error)", status.LastError)
	}
}
