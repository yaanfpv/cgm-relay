package poller_test

import (
	"bytes"
	"context"
	"errors"
	"log"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunTransientFailureRetriesAtInterval checks that a TransientError
// from the source is reported in Status without stopping Run, and that Run
// retries at the normal Interval rather than backing off.
func TestRunTransientFailureRetriesAtInterval(t *testing.T) {
	t.Parallel()
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
		t.Fatalf("current reading stores = %v, want exactly one at %s", got, recovered)
	}
}

// TestRunInvalidReadingIsSkippedNotFatal checks that a rejected store
// insert (mirroring store.ErrInvalidReading) is reported in Status and
// does not stop Run: the next tick's reading is still stored normally.
func TestRunInvalidReadingIsSkippedNotFatal(t *testing.T) {
	t.Parallel()
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
		t.Fatalf("current reading stores = %v, want exactly the second tick's reading stored", got)
	}
}

// lockedBuffer is a log destination safe to read while Run is writing.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) lines() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return strings.Split(strings.TrimSpace(b.buf.String()), "\n")
}

// TestRunLogsEachGapOnceAndSaysWhichKind drives twenty minutes in which no
// new current reading arrives for twelve, then one does, and checks Run logs
// exactly one line when the gap passes five minutes, naming whether fetches
// succeeded with nothing newer or failed, and exactly one when readings
// resume, never one per poll.
func TestRunLogsEachGapOnceAndSaysWhichKind(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	resumeAt := start.Add(12 * time.Minute)

	tests := []struct {
		name    string
		quiet   func() sourceResponse
		wantGap string
	}{
		{
			name: "source has nothing newer",
			quiet: func() sourceResponse {
				return sourceResponse{current: &cgm.Reading{Time: start.Add(-45 * time.Second), MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}}
			},
			wantGap: "LibreLinkUp has nothing newer",
		},
		{
			name: "fetches failing",
			quiet: func() sourceResponse {
				return sourceResponse{err: &cgm.TransientError{Err: errors.New("network timeout")}}
			},
			wantGap: "fetches are failing (temporary fetch failure)",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			clock := newFakeClock(start)
			src := &fakeSource{respond: func(call int) sourceResponse {
				if call == 0 {
					return sourceResponse{current: &cgm.Reading{Time: start.Add(-45 * time.Second), MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}}
				}
				if now := clock.Now(); !now.Before(resumeAt) {
					return sourceResponse{current: &cgm.Reading{Time: now.Add(-45 * time.Second), MgDl: 101, Trend: cgm.TrendFlat, Source: "synthetic"}}
				}
				return tt.quiet()
			}}
			var out lockedBuffer
			p := poller.New(src, &fakeStore{}, 15*24*time.Hour, poller.WithClock(clock), poller.WithLogger(log.New(&out, "", 0)))

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- p.Run(ctx) }()

			for clock.Now().Before(start.Add(20 * time.Minute)) {
				clock.tick(clock.waitForNextWait())
			}
			clock.waitForNextWait()
			cancel()
			if err := waitDone(t, done); err != context.Canceled {
				t.Fatalf("Run returned %v, want context.Canceled", err)
			}

			got := out.lines()
			t.Logf("log lines: %q", got)
			if len(got) != 2 {
				t.Fatalf("logged %d lines, want one at the gap's start and one at its end:\n%s", len(got), strings.Join(got, "\n"))
			}
			if !strings.Contains(got[0], tt.wantGap) {
				t.Errorf("gap start line = %q, want it to say %q", got[0], tt.wantGap)
			}
			if !strings.Contains(got[1], "resumed after a gap of 1") {
				t.Errorf("gap end line = %q, want it to say readings resumed after a gap of about twelve minutes", got[1])
			}
		})
	}
}
