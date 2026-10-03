// Package poller runs the once-a-minute loop that fetches glucose readings
// from a CGM cloud account and stores them, filling gaps from history and
// pruning old readings on its own schedule.
package poller

import (
	"context"
	"io"
	"log"
	"sync"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// Interval is how often Run requests a fresh reading when nothing in the
// readings themselves says to ask sooner or later.
const Interval = time.Minute

// PruneInterval is how often Run removes readings older than its
// configured retention.
const PruneInterval = 24 * time.Hour

// DefaultFetchTimeout bounds a single Source.Fetch call. It is shorter
// than Interval so a source that never returns cannot stall the loop past
// the next tick; Run reports the timeout through Status and retries at
// the next Interval rather than treating it as fatal.
const DefaultFetchTimeout = 45 * time.Second

// Store is the subset of a reading store that Run needs: enough to persist
// one poll cycle's readings and enforce retention.
type Store interface {
	// StorePoll stores one poll cycle's history readings and current
	// reading, if any; see store.Store.StorePoll for exactly how each
	// reading's own outcome is decided.
	StorePoll(ctx context.Context, history []cgm.Reading, current *cgm.Reading) (store.PollResult, error)
	// Prune removes readings older than retention, measured back from now.
	Prune(ctx context.Context, now time.Time, retention time.Duration) (removed int64, err error)
}

// Status is a snapshot of Run's health, safe to read while Run is active.
type Status struct {
	// LastFetchTime is when Run last completed a fetch without error, or
	// the zero Time if that has never happened.
	LastFetchTime time.Time
	// LastReadingTime, LastReadingMgDl and LastReadingTrend describe the most
	// recent reading Run has stored, or the zero Time, 0 and TrendUnknown if
	// none has been stored yet.
	LastReadingTime  time.Time
	LastReadingMgDl  int
	LastReadingTrend cgm.Trend
	// SignInFailing is true while the source is rejecting the configured
	// credentials.
	SignInFailing bool
	// LastError is a short, secret-free description of the most recent
	// failure, or empty if the last attempt succeeded outright.
	LastError string
}

// Poller runs the minute-by-minute fetch loop for one CGM account.
type Poller struct {
	source       cgm.Source
	store        Store
	clock        Clock
	retention    time.Duration
	fetchTimeout time.Duration
	logger       *log.Logger

	mu     sync.Mutex
	status Status
}

// Option configures a Poller constructed by New.
type Option func(*Poller)

// WithClock overrides the clock and timer source Run uses. Tests use it to
// control time without sleeping; production code has no reason to call it.
func WithClock(c Clock) Option {
	return func(p *Poller) { p.clock = c }
}

// WithFetchTimeout overrides the deadline Run gives each Source.Fetch
// call, in place of DefaultFetchTimeout. Tests use a short one to exercise
// a Fetch that never returns without waiting out the real default.
func WithFetchTimeout(d time.Duration) Option {
	return func(p *Poller) { p.fetchTimeout = d }
}

// WithLogger sets where Run reports that readings have stopped arriving and
// that they resumed. The default discards them.
func WithLogger(l *log.Logger) Option {
	return func(p *Poller) { p.logger = l }
}

// New returns a Poller that fetches from source once a minute, stores
// results in st, and prunes readings older than retention once a day.
// Callers pass their store's own documented default retention unless they
// have a reason to keep more or less history.
func New(source cgm.Source, st Store, retention time.Duration, opts ...Option) *Poller {
	p := &Poller{
		source:       source,
		store:        st,
		clock:        realClock{},
		retention:    retention,
		fetchTimeout: DefaultFetchTimeout,
		logger:       log.New(io.Discard, "", 0),
	}
	for _, opt := range opts {
		opt(p)
	}
	return p
}

// Status returns a snapshot of Run's current health.
func (p *Poller) Status() Status {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.status
}
