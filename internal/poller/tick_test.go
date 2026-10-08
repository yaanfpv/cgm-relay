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

// publication is one reading becoming current at the source: at is when it
// first appears, reading is its own timestamp. It stays current until the next
// publication.
type publication struct{ at, reading time.Time }

// lagged publishes a reading about every 60 s give or take 3 s, each visible
// lag(rng) after its own timestamp, and never stamped earlier than 5 s after
// the reading before.
func lagged(start time.Time, day time.Duration, lag func(rng *rand.Rand) time.Duration) func(rng *rand.Rand) []publication {
	return func(rng *rand.Rand) []publication {
		var pubs []publication
		for k := 0; time.Duration(k)*time.Minute < day+10*time.Minute; k++ {
			upload := start.Add(time.Duration(k)*time.Minute + time.Duration(rng.Intn(6001)-3000)*time.Millisecond)
			reading := upload.Add(-lag(rng))
			if n := len(pubs); n > 0 && reading.Before(pubs[n-1].reading.Add(5*time.Second)) {
				reading = pubs[n-1].reading.Add(5 * time.Second)
			}
			pubs = append(pubs, publication{at: upload, reading: reading})
		}
		return pubs
	}
}

// uneven stamps a reading every minute and publishes each one 3 to 70 s later,
// the lag now and then jumping to a new value, with consecutive publications
// held between 20 s and 100 s apart. A phone that uploads late and then
// catches up makes publications bunch together and then spread out.
func uneven(start time.Time, day time.Duration) func(rng *rand.Rand) []publication {
	return func(rng *rand.Rand) []publication {
		var pubs []publication
		lag := 30 * time.Second
		for k := 0; time.Duration(k)*time.Minute < day+10*time.Minute; k++ {
			if rng.Intn(3) == 0 {
				lag = 3*time.Second + time.Duration(rng.Intn(67001))*time.Millisecond
			}
			stamp := start.Add(time.Duration(k-1)*time.Minute + time.Duration(rng.Intn(2001)-1000)*time.Millisecond)
			at := stamp.Add(lag)
			if n := len(pubs); n > 0 {
				at = minTime(maxTime(at, pubs[n-1].at.Add(20*time.Second)), pubs[n-1].at.Add(100*time.Second))
			}
			pubs = append(pubs, publication{at: at, reading: stamp})
		}
		return pubs
	}
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

// simulate runs the poller against pubs from start until until has passed and
// returns the timestamps it stored and when each request was made. The source
// shows the latest publication already made at the moment of a request.
func simulate(t *testing.T, start, until time.Time, pubs []publication) (map[time.Time]bool, []time.Time) {
	t.Helper()
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

	for clock.Now().Before(until) {
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
	return stored, requests
}

// checkStored fails the test for every reading that stayed current at the
// source for at least 20 s, was published between start and two minutes before
// the last request, and was never stored.
func checkStored(t *testing.T, start time.Time, pubs []publication, stored map[time.Time]bool, requests []time.Time) {
	t.Helper()
	last := requests[len(requests)-1]
	published, missed := 0, 0
	for k, pub := range pubs {
		if pub.at.Before(start) || pub.at.After(last.Add(-2*time.Minute)) {
			continue
		}
		// A reading is only owed a store if it stays current at the source
		// for at least 20 s; the next upload ends that.
		if k+1 < len(pubs) && pubs[k+1].at.Sub(pub.at) < 20*time.Second {
			continue
		}
		published++
		if !stored[pub.reading] {
			missed++
			if missed <= 5 {
				t.Logf("reading stamped %s, current from %s to %s, was never stored", pub.reading.Format("15:04:05"), pub.at.Format("15:04:05"), pubs[k+1].at.Format("15:04:05"))
			}
		}
	}
	if missed != 0 {
		t.Errorf("%d of %d published readings were never stored", missed, published)
	}
	t.Logf("stored %d of %d published readings with %d requests in %.0f minutes", published-missed, published, len(requests), last.Sub(start).Minutes())
}

// checkSchedule fails the test if requests average more than maxPerMinute or
// any two are closer than 10 s.
func checkSchedule(t *testing.T, start time.Time, requests []time.Time, maxPerMinute float64) {
	t.Helper()
	minutes := requests[len(requests)-1].Sub(start).Minutes()
	if rate := float64(len(requests)) / minutes; rate > maxPerMinute {
		t.Errorf("%d requests in %.0f minutes = %.2f a minute, want at most %.1f", len(requests), minutes, rate, maxPerMinute)
	}
	for i := 1; i < len(requests); i++ {
		if gap := requests[i].Sub(requests[i-1]); gap < 10*time.Second {
			t.Fatalf("requests %d and %d are %s apart, want at least 10s", i-1, i, gap)
		}
	}
}

// TestRunStoresEveryPublishedReadingOverADay publishes a day of readings the
// way the source does (an upload about every 60 s give or take 3 s, each
// visible some time after its own timestamp), starts polling exactly on an
// upload moment, and checks every reading that stays current for at least
// 20 s is stored while requests stay under 1.5 a minute (2 for uneven
// uploads) and never closer than 10 s. One row keeps the upload lag steady and
// slow; one switches abruptly between a fast regime and a slow one, so no
// fixed polling phase can keep up; the last has uploads bunching up and
// spreading out. A reading never carries an earlier timestamp than the one
// before it.
func TestRunStoresEveryPublishedReadingOverADay(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	const day = 24 * time.Hour

	slowLag := func(rng *rand.Rand) time.Duration {
		return 38*time.Second + time.Duration(rng.Intn(10001))*time.Millisecond
	}
	regimes := func() func(rng *rand.Rand) time.Duration {
		fast := true
		return func(rng *rand.Rand) time.Duration {
			if rng.Intn(6) == 0 {
				fast = !fast
			}
			if fast {
				return 3*time.Second + time.Duration(rng.Intn(22001))*time.Millisecond
			}
			return 40*time.Second + time.Duration(rng.Intn(25001))*time.Millisecond
		}
	}

	tests := []struct {
		name         string
		seed         int64
		publish      func(rng *rand.Rand) []publication
		maxPerMinute float64
	}{
		{name: "slow uploads", seed: 7, publish: lagged(start, day, slowLag), maxPerMinute: 1.5},
		{name: "fast and slow uploads", seed: 11, publish: lagged(start, day, regimes()), maxPerMinute: 1.5},
		{name: "uneven uploads", seed: 3, publish: uneven(start, day), maxPerMinute: 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			pubs := tt.publish(rand.New(rand.NewSource(tt.seed)))
			stored, requests := simulate(t, start, start.Add(day), pubs)
			checkStored(t, start, pubs, stored, requests)
			checkSchedule(t, start, requests, tt.maxPerMinute)
		})
	}
}

// TestRunStoresAReadingThatIsCurrentForTwentySeconds replays two sequences
// where minutely readings stamped -60, 0, 60 and 120 s reach the source late
// and then close together, so the reading stamped 60 s is current for only a
// short while before the next one replaces it. Steady uploads follow.
func TestRunStoresAReadingThatIsCurrentForTwentySeconds(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	s := time.Second

	tests := []struct {
		name string
		at   []time.Duration // when the first four readings are published
	}{
		{"current for 20 s", []time.Duration{0, 60 * s, 100 * s, 120 * s}},
		{"current for 40 s", []time.Duration{0, 60 * s, 80 * s, 120 * s}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var pubs []publication
			for k := 0; k < 20; k++ {
				stamp := start.Add(time.Duration(k-1) * time.Minute)
				at := stamp.Add(30 * s)
				if k < len(tt.at) {
					at = start.Add(tt.at[k])
				}
				pubs = append(pubs, publication{at: at, reading: stamp})
			}
			stored, requests := simulate(t, start, start.Add(15*time.Minute), pubs)
			if want := start.Add(time.Minute); !stored[want] {
				t.Errorf("reading stamped %s was never stored; first requests at %v", want.Format("15:04:05"), requests[:6])
			}
			checkStored(t, start, pubs, stored, requests)
			checkSchedule(t, start, requests, 2)
		})
	}
}
