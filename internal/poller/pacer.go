package poller

import (
	"fmt"
	"log"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

const (
	// uploadLatency is a little above the slowest upload lag seen between a
	// reading's own timestamp and its appearing at the source. A reading
	// older than an Interval plus this has outlived its minute, so the next
	// one is already due.
	uploadLatency = 70 * time.Second

	// fetchLead is how much sooner than an Interval the next fetch is aimed.
	// The upload's own jitter and an unknown upload lag make the right phase
	// impossible to read from one timestamp, and a fetch phase left to wander
	// can creep to the end of one reading's minute and step over the next.
	// Aiming a little early instead makes the phase creep the other way until
	// a fetch lands just before an upload, which the retry then corrects.
	fetchLead = 5 * time.Second

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

	// skipThreshold is how much newer a new current reading must be than the
	// previous new one before the readings in between count as never fetched.
	skipThreshold = 90 * time.Second
)

// pacer schedules fetches from what they return. The source publishes a new
// current reading about once a minute, and a phone's upload lag can change
// from a few seconds to over a minute between one reading and the next, so a
// reading's age says little about when the next one lands. Instead every new
// reading is followed by a fetch about an Interval later, and a fetch that
// finds the same reading again retries soon, so each reading is caught
// whichever side of its upload the fetch falls.
type pacer struct {
	// started is when the first fetch finished, bounding how long a source
	// that has returned no reading at all is asked again soon.
	started time.Time
	last    time.Time
	// seeking is true while the last fetch returned a reading, so a repeat
	// of it, however young it was when first seen, means the next upload is
	// merely late rather than absent. A fetch with no current reading leaves
	// it alone, so an interruption does not cancel a retry a repeat earns.
	seeking bool
}

// observe takes the current reading of a successful fetch made at now and
// returns how long to wait before the next one, and whether the reading is
// newer than any seen before.
func (c *pacer) observe(now time.Time, cur *cgm.Reading) (time.Duration, bool) {
	if c.started.IsZero() {
		c.started = now
	}
	if cur == nil {
		// Nothing current: a reading may be published any moment, so ask
		// again soon, from the last reading's timestamp or, before any, from
		// the start, until it is implausible and then fall back to an Interval.
		since := c.last
		if since.IsZero() {
			since = c.started
		}
		if now.Sub(since) <= staleAfter {
			return uploadRetry, false
		}
		return Interval, false
	}
	age := now.Sub(cur.Time)
	if cur.Time.After(c.last) {
		c.last = cur.Time
		c.seeking = true
		if age > Interval+uploadLatency {
			// The next upload may already be due.
			return minFetchGap, true
		}
		return Interval - fetchLead, true
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
	// skipFrom and skipTo hold the timestamps of a jump that ends a gap, for
	// the resume line to name.
	skipFrom, skipTo time.Time
}

// skippedText names the two timestamps of a jump, and nothing else.
func skippedText(previous, current time.Time) string {
	return fmt.Sprintf("LibreLinkUp's current reading went from %s to %s, so the readings between were never fetched",
		previous.UTC().Format(time.RFC3339), current.UTC().Format(time.RFC3339))
}

// checkSkipped is called for every new current reading with the timestamp of
// the previous new one. When the new one is so much later that the readings
// between were never current in any fetch, it logs one line naming both
// timestamps, never a glucose value. A jump that ends a reported gap is not
// logged here: the resume line carries it.
func (g *gapWatch) checkSkipped(previous, current time.Time) {
	if previous.IsZero() || current.Sub(previous) <= skipThreshold {
		return
	}
	if g.inGap {
		g.skipFrom, g.skipTo = previous, current
		return
	}
	g.logger.Printf("poller: %s", skippedText(previous, current))
}

// check is called after every fetch. fresh says a new current reading
// arrived; failure is the short description of the fetch's error, empty when
// the fetch succeeded.
func (g *gapWatch) check(now time.Time, fresh bool, failure string) {
	if fresh {
		if g.inGap {
			resumed := "poller: readings resumed after a gap of " + now.Sub(g.lastNew).Round(time.Second).String()
			if !g.skipTo.IsZero() {
				resumed += ": " + skippedText(g.skipFrom, g.skipTo)
			}
			g.logger.Print(resumed)
			g.inGap = false
			g.skipFrom, g.skipTo = time.Time{}, time.Time{}
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
