package poller

import (
	"log"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

const (
	// uploadLatency is how long after a reading's own timestamp the next
	// reading is expected to be visible at the source, set just above the
	// slowest observed upload lag so a fetch scheduled for it lands after the
	// upload rather than on it.
	uploadLatency = 50 * time.Second

	// minFreshAge is the youngest a reading can be when read at an upload;
	// anything younger says nothing about when the next upload comes.
	minFreshAge = 30 * time.Second

	// uploadRetry is how soon to ask again when an expected upload has not
	// appeared yet.
	uploadRetry = 15 * time.Second

	// minFetchGap keeps two requests from ever being closer than this.
	minFetchGap = 10 * time.Second

	// staleAfter is the reading age past which a missing upload is treated
	// as the source having nothing newer, so retries stop.
	staleAfter = Interval + uploadLatency + 15*time.Second

	// gapThreshold is how long without a new current reading counts as a gap
	// worth logging.
	gapThreshold = 5 * time.Minute
)

// pacer schedules fetches from the readings themselves. The source publishes
// a new current reading about once a minute, a fixed delay after the
// reading's own timestamp, so timing the next fetch from that timestamp keeps
// every fetch just after an upload instead of letting its phase drift across
// one and read the same reading twice.
type pacer struct {
	last time.Time
	// seeking is true while the last new reading was read at a plausible
	// upload age, so a repeat of it means the next upload is merely late.
	seeking bool
}

// observe takes the current reading of a successful fetch made at now and
// returns how long to wait before the next one, and whether the reading is
// newer than any seen before.
func (c *pacer) observe(now time.Time, cur *cgm.Reading) (time.Duration, bool) {
	if cur == nil {
		c.seeking = false
		return Interval, false
	}
	age := now.Sub(cur.Time)
	if cur.Time.After(c.last) {
		c.last = cur.Time
		if age < minFreshAge || age > Interval+uploadLatency {
			c.seeking = false
			return Interval, true
		}
		c.seeking = true
		return max(Interval+uploadLatency-age, minFetchGap), true
	}
	if c.seeking && age <= staleAfter {
		return uploadRetry, false
	}
	c.seeking = false
	return Interval, false
}

// gapWatch logs one line when readings stop arriving and one when they
// resume, saying which kind of stop it is.
type gapWatch struct {
	lastNew time.Time
	inGap   bool
	logger  *log.Logger
}

// check is called after every fetch. fresh says a new current reading
// arrived; failure is the short description of the fetch's error, empty when
// the fetch succeeded.
func (g *gapWatch) check(now time.Time, fresh bool, failure string) {
	if fresh {
		if g.inGap {
			g.logger.Printf("poller: readings resumed after a gap of %s", now.Sub(g.lastNew).Round(time.Second))
			g.inGap = false
		}
		g.lastNew = now
		return
	}
	if g.inGap || now.Sub(g.lastNew) < gapThreshold {
		return
	}
	g.inGap = true
	gap := now.Sub(g.lastNew).Round(time.Second)
	if failure != "" {
		g.logger.Printf("poller: no new reading for %s: fetches are failing (%s)", gap, failure)
		return
	}
	g.logger.Printf("poller: no new reading for %s: fetches succeed but LibreLinkUp has nothing newer", gap)
}
