package poller_test

import (
	"context"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunFetchTimeoutIsReportedAndRetried checks that a Source.Fetch call
// that never returns is bounded by its own deadline rather than stalling
// the loop: Run reports the timeout through Status, keeps going, and
// retries at the next Interval.
func TestRunFetchTimeoutIsReportedAndRetried(t *testing.T) {
	t.Parallel()
	clock := newFakeClock(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	src := newBlockingSource() // never returns on its own; only its ctx ends it
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour,
		poller.WithClock(clock),
		poller.WithFetchTimeout(20*time.Millisecond),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	select {
	case <-src.started:
	case <-time.After(time.Second):
		t.Fatal("Fetch was never called within 1s of starting Run")
	}

	// The fetch deadline is real wall-clock time (context.WithTimeout does
	// not go through the injected Clock), so this blocks for up to
	// roughly the fetch timeout before Run registers its next wait on the
	// fake clock.
	w := clock.waitForNextWait()
	if w != poller.Interval {
		t.Fatalf("wait after a fetch timeout = %s, want the normal Interval (%s)", w, poller.Interval)
	}
	if status := p.Status(); status.LastError == "" {
		t.Error("Status().LastError empty after a fetch timeout, want it set")
	}

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
}

// TestRunStopsPromptlyEvenWithAFetchTimeoutConfigured checks that
// cancelling Run's own context still stops it within a second when a
// fetch timeout is configured, so the timeout mechanism never delays
// ordinary shutdown.
func TestRunStopsPromptlyEvenWithAFetchTimeoutConfigured(t *testing.T) {
	t.Parallel()
	src := newBlockingSource()
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithFetchTimeout(time.Minute))

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
