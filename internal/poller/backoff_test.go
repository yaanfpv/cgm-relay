package poller_test

import (
	"context"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunRateLimitBackoffAndReset drives Run through three consecutive
// rate-limit responses, a success, and then one more rate limit, checking
// the exact wait Run asks the clock for at each step: the fixed schedule
// (60s, 120s, 300s), the source's own RetryAfter when it is longer than
// that schedule, about an Interval right after a success, and the
// schedule restarting at 60s rather than continuing from 300s.
func TestRunRateLimitBackoffAndReset(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)

	rateLimited := func(retryAfter time.Duration) sourceResponse {
		return sourceResponse{err: &cgm.RateLimitError{RetryAfter: retryAfter}}
	}
	success := sourceResponse{current: &cgm.Reading{Time: start, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}}
	src := scriptedSource([]sourceResponse{
		rateLimited(0),                 // call 0: base 60s beats a shorter RetryAfter
		rateLimited(90 * time.Second),  // call 1: base 120s beats RetryAfter 90s
		rateLimited(400 * time.Second), // call 2: RetryAfter 400s beats base 300s
		success,                        // call 3: resets the backoff count
		rateLimited(0),                 // call 4: back at the start of the schedule
	})
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	var got []time.Duration
	for i := 0; i < 5; i++ {
		w := clock.waitForNextWait()
		got = append(got, w)
		clock.tick(w)
	}

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}

	want := []time.Duration{
		60 * time.Second,
		120 * time.Second,
		400 * time.Second,
		0, // a success waits about an Interval, checked below
		60 * time.Second,
	}
	if len(got) != len(want) {
		t.Fatalf("waits = %v, want %v", got, want)
	}
	if got[3] <= 0 || got[3] > poller.Interval {
		t.Errorf("wait[3] = %s after a success, want at most the normal Interval (%s)", got[3], poller.Interval)
	}
	for i := range want {
		if i == 3 {
			continue
		}
		if got[i] != want[i] {
			t.Errorf("wait[%d] = %s, want %s", i, got[i], want[i])
		}
	}
}

// TestRunRateLimitReportsStatus checks that a rate limit is reflected in
// Status without marking sign-in as failing, which is a distinct kind of
// trouble.
func TestRunRateLimitReportsStatus(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)
	src := scriptedSource([]sourceResponse{{err: &cgm.RateLimitError{RetryAfter: 30 * time.Second}}})
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	clock.waitForNextWait()
	status := p.Status()
	if status.LastError == "" {
		t.Error("Status().LastError empty while rate limited, want it set")
	}
	if status.SignInFailing {
		t.Error("Status().SignInFailing = true for a rate limit, want false")
	}

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
}
