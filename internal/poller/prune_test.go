package poller_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunPrunesOncePerDay runs two days of one-minute cycles after the
// initial fetch and checks Prune is called exactly three times -- once
// immediately on the first cycle, then once per elapsed day, never zero
// times and never once per tick.
func TestRunPrunesOncePerDay(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)

	src := scriptedSource([]sourceResponse{
		{current: &cgm.Reading{Time: start, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	st := &fakeStore{}
	const retention = 15 * 24 * time.Hour
	p := poller.New(src, st, retention, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	// A cycle can end a little short of a minute, so run on past two days
	// by a couple of minutes to be sure of the cycle that is due at 48h.
	for clock.Now().Before(start.Add(2*24*time.Hour + 2*poller.Interval)) {
		clock.tick(clock.waitForNextWait())
	}
	// The last tick only releases Run to run its final fetchAndStore and
	// prune check; wait for the timer that follows it, proving that check
	// has completed, before reading the prune count.
	clock.waitForNextWait()

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
	if got := st.pruneCallCount(); got != 3 {
		t.Fatalf("Prune called %d times over two days of cycles, want 3 (immediate, +24h, +48h)", got)
	}
}

// TestRunPrunesOnFirstCycleEvenIfCancelledEarly checks that Run enforces
// retention on its very first cycle, before a single PruneInterval has
// elapsed -- otherwise a relay that never stays up for a full day would
// never prune at all.
func TestRunPrunesOnFirstCycleEvenIfCancelledEarly(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)

	src := scriptedSource([]sourceResponse{
		{current: &cgm.Reading{Time: start, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	// Wait for Run to register the timer that follows its first cycle,
	// proving that cycle's prune check has completed, without letting any
	// simulated time pass at all.
	clock.waitForNextWait()

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
	if got := st.pruneCallCount(); got != 1 {
		t.Fatalf("Prune called %d times on the first cycle, want 1", got)
	}
}

// TestRunPruneFailureIsReportedNotFatal checks that a failed Prune call is
// reported through Status rather than stopping Run.
func TestRunPruneFailureIsReportedNotFatal(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)

	src := scriptedSource([]sourceResponse{
		{current: &cgm.Reading{Time: start, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	st := &fakeStore{pruneErr: errors.New("disk full")}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	for clock.Now().Before(start.Add(24 * time.Hour)) {
		clock.tick(clock.waitForNextWait())
	}
	clock.waitForNextWait()

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
	if got := st.pruneCallCount(); got != 2 {
		t.Fatalf("Prune called %d times, want 2 (immediate, then +24h)", got)
	}
	if status := p.Status(); status.LastError == "" {
		t.Error("Status().LastError empty after a failed prune, want it set")
	}
}
