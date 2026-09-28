package poller_test

import (
	"context"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunStopsWithinOneSecondMidWait cancels ctx while Run is blocked
// waiting for its next tick and checks Run returns promptly. Run's loop
// never spawns a goroutine of its own, so its own return over the done
// channel is a complete proof that nothing of Run's is left running.
func TestRunStopsWithinOneSecondMidWait(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)
	src := scriptedSource([]sourceResponse{
		{current: &cgm.Reading{Time: start, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	clock.waitForNextWait() // Run is now blocked in wait(), mid-wait

	started := time.Now()
	cancel()
	err := waitDone(t, done)
	if err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Errorf("Run took %s to stop after cancellation, want under 1s", elapsed)
	}
}

// TestRunStopsWithinOneSecondMidFetch cancels ctx while Run is inside
// Source.Fetch and checks Run still returns promptly rather than waiting
// for the fetch to finish some other way.
func TestRunStopsWithinOneSecondMidFetch(t *testing.T) {
	t.Parallel()
	src := newBlockingSource()
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	select {
	case <-src.started:
	case <-time.After(time.Second):
		t.Fatal("Fetch was never called within 1s of starting Run")
	}

	started := time.Now()
	cancel()
	err := waitDone(t, done)
	if err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Errorf("Run took %s to stop after cancellation, want under 1s", elapsed)
	}
}
