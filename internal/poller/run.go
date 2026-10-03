package poller

import (
	"context"
	"errors"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// authRetryInterval bounds how often Run retries after the source reports
// an authentication failure.
const authRetryInterval = 5 * time.Minute

// rateLimitBackoff is the wait Run uses after consecutive rate-limit
// responses, indexed by how many have happened in a row since the last
// success (capped at the last entry once that count runs out).
var rateLimitBackoff = []time.Duration{60 * time.Second, 120 * time.Second, 300 * time.Second}

// Run fetches a reading about once an Interval, timed from the readings
// themselves so none the source publishes is skipped, storing it and filling
// any history gaps, until ctx is done. It prunes on its first cycle and every
// PruneInterval after that, so retention is enforced even across frequent
// restarts. It backs off after a rate limit or an authentication failure
// and retries a transient failure, a fetch that timed out, or a rejected
// store insert at the next Interval; none of those stop the loop. Run
// returns ctx's own error once ctx is done, and for no other reason.
func (p *Poller) Run(ctx context.Context) error {
	// Starting lastPrune a full PruneInterval in the past makes the very
	// first cycle's check due immediately, so retention is enforced from
	// the first fetch onward rather than only after a full PruneInterval
	// of continuous uptime -- otherwise a relay that restarts daily, or
	// crashes and comes back, would never prune at all.
	lastPrune := p.clock.Now().Add(-PruneInterval)
	rateLimitAttempt := 0
	var pace pacer
	gaps := gapWatch{lastNew: p.clock.Now(), logger: p.logger}

	for {
		if err := ctx.Err(); err != nil {
			return err
		}

		wait, err := p.fetchAndStore(ctx, &rateLimitAttempt, &pace, &gaps)
		if err != nil {
			return err
		}

		if now := p.clock.Now(); now.Sub(lastPrune) >= PruneInterval {
			p.prune(ctx, now)
			lastPrune = now
		}

		if err := p.wait(ctx, wait); err != nil {
			return err
		}
	}
}

// fetchAndStore runs one fetch-and-store cycle: it calls Source.Fetch
// under its own deadline (p.fetchTimeout), stores the current reading (if
// any) and any history readings, updates Status to match, and returns how
// long Run should wait before the next cycle. rateLimitAttempt is the
// running count of consecutive rate-limit responses since the last
// success; fetchAndStore updates it in place. pace and gaps carry the
// schedule and the reading-gap log state between cycles. The only error
// fetchAndStore returns is ctx's own error, once ctx is done -- a fetch
// that timed out, or any other fetch or store failure, is reported through
// Status, never returned.
func (p *Poller) fetchAndStore(ctx context.Context, rateLimitAttempt *int, pace *pacer, gaps *gapWatch) (time.Duration, error) {
	fetchCtx, cancelFetch := context.WithTimeout(ctx, p.fetchTimeout)
	current, history, err := p.source.Fetch(fetchCtx)
	cancelFetch()
	if ctxErr := ctx.Err(); ctxErr != nil {
		return 0, ctxErr
	}
	if err != nil {
		wait, failure := p.handleFetchError(err, rateLimitAttempt)
		gaps.check(p.clock.Now(), false, failure)
		return wait, nil
	}

	*rateLimitAttempt = 0
	p.recordSuccess()

	result, storeErr := p.store.StorePoll(ctx, history, current)
	if storeErr != nil {
		// The whole write failed -- nothing from this cycle was stored.
		// The per-row outcomes in result are meaningless here (see
		// StorePoll), so there is nothing left to check them against.
		p.recordStoreError()
	} else {
		for _, hr := range result.History {
			if hr.Outcome == store.PollInvalid {
				p.recordStoreError()
			}
		}
		if current != nil && result.Current != nil {
			if result.Current.Outcome == store.PollInvalid {
				p.recordStoreError()
			} else {
				p.recordStored(*current)
			}
		}
	}

	now := p.clock.Now()
	wait, fresh := pace.observe(now, current)
	gaps.check(now, fresh, "")
	return wait, nil
}

// handleFetchError classifies a Source.Fetch error, records it on Status,
// and returns how long Run should wait before retrying, with the same
// secret-free description it recorded.
func (p *Poller) handleFetchError(err error, rateLimitAttempt *int) (time.Duration, string) {
	var rateLimitErr *cgm.RateLimitError
	var authErr *cgm.AuthError
	var transientErr *cgm.TransientError

	switch {
	case errors.As(err, &rateLimitErr):
		wait := rateLimitBackoff[min(*rateLimitAttempt, len(rateLimitBackoff)-1)]
		if rateLimitErr.RetryAfter > wait {
			wait = rateLimitErr.RetryAfter
		}
		*rateLimitAttempt++
		p.recordFailure("rate limited, backing off", false)
		return wait, "rate limited"

	case errors.As(err, &authErr):
		p.recordFailure("sign-in failed", true)
		return authRetryInterval, "sign-in failed"

	case errors.As(err, &transientErr), errors.Is(err, context.DeadlineExceeded):
		p.recordFailure("temporary fetch failure, retrying", false)
		return Interval, "temporary fetch failure"

	default:
		p.recordFailure("fetch failed, retrying", false)
		return Interval, "fetch failed"
	}
}

// wait blocks for d, or until ctx is done, whichever comes first.
func (p *Poller) wait(ctx context.Context, d time.Duration) error {
	t := p.clock.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C():
		return nil
	}
}

// prune removes readings older than p.retention and records a failure on
// Status if that did not work; a pruning failure never stops Run.
func (p *Poller) prune(ctx context.Context, now time.Time) {
	if _, err := p.store.Prune(ctx, now, p.retention); err != nil {
		p.mu.Lock()
		p.status.LastError = "failed to prune old readings"
		p.mu.Unlock()
	}
}

func (p *Poller) recordSuccess() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.status.LastFetchTime = p.clock.Now()
	p.status.SignInFailing = false
	p.status.LastError = ""
}

func (p *Poller) recordFailure(msg string, signInFailing bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.status.SignInFailing = signInFailing
	p.status.LastError = msg
}

func (p *Poller) recordStored(r cgm.Reading) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.status.LastReadingTime = r.Time
	p.status.LastReadingMgDl = r.MgDl
	p.status.LastReadingTrend = r.Trend
}

func (p *Poller) recordStoreError() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.status.LastError = "failed to store reading"
}
