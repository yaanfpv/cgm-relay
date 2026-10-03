package poller_test

import (
	"context"
	"math/rand"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// TestRunStoresOneCurrentReadingPerTick drives ten ticks past Run's
// initial, immediate fetch and checks that the current reading was stored
// exactly once per tick, each with a distinct reading, so neither a missed
// tick nor a duplicate store can hide in the count.
func TestRunStoresOneCurrentReadingPerTick(t *testing.T) {
	t.Parallel()
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
		t.Fatalf("current reading stored %d times, want %d", len(got), wantCalls)
	}
	seen := map[time.Time]bool{}
	for _, ts := range got {
		if seen[ts] {
			t.Errorf("reading at %s was stored more than once", ts)
		}
		seen[ts] = true
	}
}

// TestRunRoutesHistoryAndSkipsNilCurrent checks that history readings are
// passed through as StorePoll's history slice, that a nil current reading
// stores nothing and is not treated as an error, and that a later tick
// with a real current reading still stores normally.
func TestRunRoutesHistoryAndSkipsNilCurrent(t *testing.T) {
	t.Parallel()
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
		t.Fatalf("history readings stored %d times, want 2 (from %v)", len(got), got)
	}
	if got := st.currentTimes(); len(got) != 1 || got[0] != nextReading {
		t.Fatalf("current reading stores = %v, want exactly one at %s", got, nextReading)
	}
	if status := p.Status(); status.LastError != "" {
		t.Errorf("Status().LastError = %q after a nil current reading, want empty (a nil current is not an error)", status.LastError)
	}
}

// TestRunStoresEveryPublishedReadingOverADay publishes a day of readings the
// way the source does (an upload about every 60 s give or take 3 s, each
// visible 38 to 48 s after its own timestamp), starts polling exactly on an
// upload moment, and checks every reading is stored while requests stay
// under 1.5 a minute and never closer than 10 s.
func TestRunStoresEveryPublishedReadingOverADay(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	const day = 24 * time.Hour
	rng := rand.New(rand.NewSource(7))

	type publication struct{ at, reading time.Time }
	var pubs []publication
	for k := 0; time.Duration(k)*time.Minute < day+10*time.Minute; k++ {
		upload := start.Add(time.Duration(k)*time.Minute + time.Duration(rng.Intn(6001)-3000)*time.Millisecond)
		lag := 38*time.Second + time.Duration(rng.Intn(10001))*time.Millisecond
		pubs = append(pubs, publication{at: upload, reading: upload.Add(-lag)})
	}

	clock := newFakeClock(start)
	var mu sync.Mutex
	var requests []time.Time
	src := &fakeSource{respond: func(int) sourceResponse {
		now := clock.Now()
		mu.Lock()
		requests = append(requests, now)
		mu.Unlock()
		i := sort.Search(len(pubs), func(i int) bool { return pubs[i].at.After(now) })
		if i == 0 {
			return sourceResponse{}
		}
		return sourceResponse{current: &cgm.Reading{Time: pubs[i-1].reading, MgDl: 100, Trend: cgm.TrendFlat, Source: "synthetic"}}
	}}
	st := &fakeStore{}
	p := poller.New(src, st, 15*24*time.Hour, poller.WithClock(clock))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()

	for clock.Now().Before(start.Add(day)) {
		clock.tick(clock.waitForNextWait())
	}
	clock.waitForNextWait()
	cancel()
	if err := waitDone(t, done); err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}

	stored := map[time.Time]bool{}
	for _, ts := range st.currentTimes() {
		stored[ts] = true
	}
	last := requests[len(requests)-1]
	published, missed := 0, 0
	for _, pub := range pubs {
		if pub.at.Before(start) || pub.at.After(last.Add(-2*time.Minute)) {
			continue
		}
		published++
		if !stored[pub.reading] {
			missed++
		}
	}
	if missed != 0 {
		t.Errorf("%d of %d published readings were never stored", missed, published)
	}

	minutes := last.Sub(start).Minutes()
	t.Logf("stored %d of %d published readings with %d requests in %.0f minutes", published-missed, published, len(requests), minutes)
	if rate := float64(len(requests)) / minutes; rate > 1.5 {
		t.Errorf("%d requests in %.0f minutes = %.2f a minute, want at most 1.5", len(requests), minutes, rate)
	}
	for i := 1; i < len(requests); i++ {
		if gap := requests[i].Sub(requests[i-1]); gap < 10*time.Second {
			t.Fatalf("requests %d and %d are %s apart, want at least 10s", i-1, i, gap)
		}
	}
}
