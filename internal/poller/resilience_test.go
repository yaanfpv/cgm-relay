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
	if w <= 0 || w > poller.Interval {
		t.Fatalf("wait after a rejected store insert = %s, want at most the normal Interval (%s)", w, poller.Interval)
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
			// The reading that ends the gap is far newer than the last new
			// one, so the resume line names both timestamps.
			for _, want := range []string{"went from 2025-12-31T23:59:15Z to 2026-01-01T00:1", "never fetched"} {
				if !strings.Contains(got[1], want) {
					t.Errorf("gap end line = %q, want it to contain %q", got[1], want)
				}
			}
			if strings.Contains(got[1], "101") {
				t.Errorf("gap end line = %q, must not contain a glucose value", got[1])
			}
		})
	}
}

// TestRunLogsOnceWhenTheCurrentReadingJumps checks that when LibreLinkUp's
// current reading moves more than 90 s ahead of the previous new one, Run
// logs exactly one line naming both timestamps and no glucose value, and that
// ordinary one-minute steps log nothing.
func TestRunLogsOnceWhenTheCurrentReadingJumps(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	readings := []time.Time{
		start.Add(-20 * time.Second),
		start.Add(40 * time.Second),
		start.Add(100 * time.Second),
		start.Add(220 * time.Second), // 120 s after the one before
		start.Add(280 * time.Second),
	}
	const mgDl = 187
	clock := newFakeClock(start)
	src := scriptedSource([]sourceResponse{
		{current: &cgm.Reading{Time: readings[0], MgDl: mgDl, Trend: cgm.TrendFlat, Source: "synthetic"}},
		{current: &cgm.Reading{Time: readings[1], MgDl: mgDl, Trend: cgm.TrendFlat, Source: "synthetic"}},
		{current: &cgm.Reading{Time: readings[2], MgDl: mgDl, Trend: cgm.TrendFlat, Source: "synthetic"}},
		{current: &cgm.Reading{Time: readings[3], MgDl: mgDl, Trend: cgm.TrendFlat, Source: "synthetic"}},
		{current: &cgm.Reading{Time: readings[4], MgDl: mgDl, Trend: cgm.TrendFlat, Source: "synthetic"}},
	})
	var out lockedBuffer
	p := poller.New(src, &fakeStore{}, 15*24*time.Hour, poller.WithClock(clock), poller.WithLogger(log.New(&out, "", 0)))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	for i := 0; i < len(readings)-1; i++ {
		clock.tick(clock.waitForNextWait())
	}
	clock.waitForNextWait()
	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}

	got := out.lines()
	t.Logf("log lines: %q", got)
	if len(got) != 1 {
		t.Fatalf("logged %d lines, want exactly one for the jump:\n%s", len(got), strings.Join(got, "\n"))
	}
	for _, want := range []string{readings[2].Format(time.RFC3339), readings[3].Format(time.RFC3339), "never fetched"} {
		if !strings.Contains(got[0], want) {
			t.Errorf("jump line = %q, want it to contain %q", got[0], want)
		}
	}
	if strings.Contains(got[0], "187") {
		t.Errorf("jump line = %q, must not contain a glucose value", got[0])
	}
}

// TestRunWaitsBetweenFetches drives Run with the fake clock and checks the
// exact wait it asks for after each fetch. Every row serves one reading,
// stamped firstAge before the first fetch, wherever its script says a reading
// and nothing where it says nil. A new reading is followed by a fetch 55 s
// later however young it was; a repeat of it is retried after 15 s while a
// newer one is still plausible and after 60 s once not; a reading that has
// outlived its minute is asked about again after 10 s; and a fetch with
// nothing current is retried after 15 s until two and a half minutes have
// passed since the last reading, or since the start if there was none.
func TestRunWaitsBetweenFetches(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	const (
		r       = true  // the fetch returns the reading
		nilResp = false // the fetch returns no current reading
	)
	s := time.Second
	tests := []struct {
		name     string
		firstAge time.Duration
		script   []bool
		want     []time.Duration
	}{
		{"first sight at 5 s", 5 * s, []bool{r, r}, []time.Duration{55 * s, 15 * s}},
		{"first sight at 20 s", 20 * s, []bool{r, r}, []time.Duration{55 * s, 15 * s}},
		{"first sight at 45 s", 45 * s, []bool{r, r}, []time.Duration{55 * s, 15 * s}},
		{"first sight after it outlived its minute", 135 * s, []bool{r}, []time.Duration{10 * s}},
		{"repeat once nothing newer is plausible", 20 * s, []bool{r, r, r, r, r, r, r}, []time.Duration{55 * s, 15 * s, 15 * s, 15 * s, 15 * s, 15 * s, 60 * s}},
		{"repeat after a nil within reach", 20 * s, []bool{r, nilResp, r}, []time.Duration{55 * s, 15 * s, 15 * s}},
		{"nil before any reading", 20 * s, []bool{nilResp, r}, []time.Duration{15 * s, 55 * s}},
		{"nil long after the start with no reading ever", 20 * s, []bool{nilResp, nilResp, nilResp, nilResp, nilResp, nilResp, nilResp, nilResp, nilResp, nilResp, nilResp},
			[]time.Duration{15 * s, 15 * s, 15 * s, 15 * s, 15 * s, 15 * s, 15 * s, 15 * s, 15 * s, 15 * s, 60 * s}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			clock := newFakeClock(start)
			reading := &cgm.Reading{Time: start.Add(-tt.firstAge), MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}
			src := &fakeSource{respond: func(call int) sourceResponse {
				// The tick after the last checked wait releases one more fetch.
				if tt.script[min(call, len(tt.script)-1)] {
					return sourceResponse{current: reading}
				}
				return sourceResponse{}
			}}
			p := poller.New(src, &fakeStore{}, 15*24*time.Hour, poller.WithClock(clock))

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- p.Run(ctx) }()

			for i, want := range tt.want {
				w := clock.waitForNextWait()
				if w != want {
					t.Errorf("wait after fetch %d = %s, want %s", i, w, want)
				}
				clock.tick(w)
			}
			clock.waitForNextWait()
			cancel()
			if err := waitDone(t, done); err != context.Canceled {
				t.Fatalf("Run returned %v, want context.Canceled", err)
			}
		})
	}
}
