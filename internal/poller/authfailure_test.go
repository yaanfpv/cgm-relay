package poller_test

import (
	"context"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunAuthFailureBacksOffAndClears checks that an authentication
// failure marks Status().SignInFailing, that Run retries no more often
// than once every five minutes while it persists, and that a subsequent
// success clears the flag.
func TestRunAuthFailureBacksOffAndClears(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)

	src := scriptedSource([]sourceResponse{
		{err: &cgm.AuthError{}},
		{err: &cgm.AuthError{}},
		{current: &cgm.Reading{Time: start, MgDl: 110, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	w0 := clock.waitForNextWait()
	if w0 != 5*time.Minute {
		t.Fatalf("wait after the first auth failure = %s, want 5m", w0)
	}
	if status := p.Status(); !status.SignInFailing {
		t.Fatal("Status().SignInFailing = false after an auth failure, want true")
	}
	clock.tick(w0)

	w1 := clock.waitForNextWait()
	if w1 != 5*time.Minute {
		t.Errorf("wait after a second consecutive auth failure = %s, want 5m (no faster retry)", w1)
	}
	clock.tick(w1)

	// Firing w1 lets call 2 (the success) run; wait for Run to register the
	// timer that follows it, which proves fetchAndStore for call 2 --
	// including clearing SignInFailing -- has already completed.
	clock.waitForNextWait()

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
	if status := p.Status(); status.SignInFailing {
		t.Error("Status().SignInFailing = true after a successful fetch, want false")
	}
}
