package poller_test

import (
	"sync"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// fakeClock is a deterministic poller.Clock for tests: Now only changes
// when the test calls tick, and a Timer only fires then -- no wall-clock
// time passes while a test uses it. waitForNextWait synchronizes a test
// with the goroutine it drives, so a test never advances the clock before
// Run has actually asked to wait, and never races the count of ticks it
// drives against how many Run has consumed.
type fakeClock struct {
	mu      sync.Mutex
	cond    *sync.Cond
	now     time.Time
	waiters []*fakeTimer
}

func newFakeClock(start time.Time) *fakeClock {
	c := &fakeClock{now: start}
	c.cond = sync.NewCond(&c.mu)
	return c
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) NewTimer(d time.Duration) poller.Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := &fakeTimer{clock: c, fireAt: c.now.Add(d), ch: make(chan time.Time, 1)}
	c.waiters = append(c.waiters, t)
	c.cond.Broadcast()
	return t
}

// waitForNextWait blocks until Run has registered its next timer, without
// firing it, and returns the duration Run asked to wait -- so a test can
// inspect that duration, or Status, before deciding whether to fire it.
func (c *fakeClock) waitForNextWait() time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	for len(c.waiters) == 0 {
		c.cond.Wait()
	}
	return c.waiters[0].fireAt.Sub(c.now)
}

// tick blocks until Run is waiting on a timer, as waitForNextWait does,
// then advances the clock by d and fires every pending timer d reaches.
func (c *fakeClock) tick(d time.Duration) {
	c.waitForNextWait()
	c.mu.Lock()
	c.now = c.now.Add(d)
	now := c.now
	var remaining []*fakeTimer
	for _, t := range c.waiters {
		if !t.fireAt.After(now) {
			t.fired = true
			select {
			case t.ch <- now:
			default:
			}
		} else {
			remaining = append(remaining, t)
		}
	}
	c.waiters = remaining
	c.mu.Unlock()
}

// fakeTimer is the poller.Timer newFakeClock hands out. Every field is only
// ever touched while holding clock.mu, in NewTimer, tick, or Stop.
type fakeTimer struct {
	clock   *fakeClock
	fireAt  time.Time
	ch      chan time.Time
	fired   bool
	stopped bool
}

func (t *fakeTimer) C() <-chan time.Time { return t.ch }

func (t *fakeTimer) Stop() bool {
	c := t.clock
	c.mu.Lock()
	defer c.mu.Unlock()
	if t.fired || t.stopped {
		return false
	}
	t.stopped = true
	for i, w := range c.waiters {
		if w == t {
			c.waiters = append(c.waiters[:i], c.waiters[i+1:]...)
			break
		}
	}
	return true
}
