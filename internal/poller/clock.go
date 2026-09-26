package poller

import "time"

// Clock abstracts time.Now and timers so Run's tests can control time
// without sleeping. Production code uses the default realClock; only tests
// override it, via WithClock.
type Clock interface {
	// Now returns the current time.
	Now() time.Time
	// NewTimer returns a Timer that fires once, after d.
	NewTimer(d time.Duration) Timer
}

// Timer is the subset of *time.Timer that Run needs.
type Timer interface {
	// C returns the channel the timer sends on when it fires.
	C() <-chan time.Time
	// Stop prevents the timer from firing, if it has not already. It is
	// always safe to call, fired or not.
	Stop() bool
}

// realClock is the production Clock, backed by the time package.
type realClock struct{}

func (realClock) Now() time.Time { return time.Now() }

func (realClock) NewTimer(d time.Duration) Timer {
	return realTimer{time.NewTimer(d)}
}

// realTimer adapts *time.Timer to the Timer interface.
type realTimer struct {
	t *time.Timer
}

func (r realTimer) C() <-chan time.Time { return r.t.C }

func (r realTimer) Stop() bool { return r.t.Stop() }
