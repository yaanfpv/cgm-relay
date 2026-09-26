package poller_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunTransientFailureRetriesAtInterval checks that a TransientError
// from the source is reported in Status without stopping Run, and that Run
// retries at the normal Interval rather than backing off.
func TestRunTransientFailureRetriesAtInterval(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)

	recovered := start.Add(poller.Interval)
	src := scriptedSource([]sourceResponse{
		{err: &cgm.TransientError{Err: errors.New("network timeout")}},
		{current: &cgm.Reading{Time: recovered, MgDl: 105, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	w := clock.waitForNextWait()
	if w != poller.Interval {
		t.Fatalf("wait after a transient failure = %s, want the normal Interval (%s)", w, poller.Interval)
	}
	if status := p.Status(); status.LastError == "" {
		t.Error("Status().LastError empty after a transient failure, want it set")
	}
	clock.tick(w)

	// That tick only releases Run to run the recovery fetch; wait for the
	// timer that follows it, proving the store call has completed.
	clock.waitForNextWait()

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
	if got := st.currentTimes(); len(got) != 1 || got[0] != recovered {
		t.Fatalf("InsertCurrent calls = %v, want exactly one at %s", got, recovered)
	}
}

// TestRunInvalidReadingIsSkippedNotFatal checks that a rejected store
// insert (mirroring store.ErrInvalidReading) is reported in Status and
// does not stop Run: the next tick's reading is still stored normally.
func TestRunInvalidReadingIsSkippedNotFatal(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := newFakeClock(start)

	second := start.Add(poller.Interval)
	src := scriptedSource([]sourceResponse{
		{current: &cgm.Reading{Time: start, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}},
		{current: &cgm.Reading{Time: second, MgDl: 105, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	st := &fakeStore{currentErrs: []error{errors.New("store: invalid reading: zero Time")}}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	w := clock.waitForNextWait()
	if w != poller.Interval {
		t.Fatalf("wait after a rejected store insert = %s, want the normal Interval (%s)", w, poller.Interval)
	}
	if status := p.Status(); status.LastError == "" {
		t.Error("Status().LastError empty after a rejected insert, want it set")
	}
	clock.tick(w)

	clock.waitForNextWait()

	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}
	if got := st.currentTimes(); len(got) != 1 || got[0] != second {
		t.Fatalf("InsertCurrent calls = %v, want exactly the second tick's reading stored", got)
	}
}
