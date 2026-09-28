package poller_test

import (
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/poller"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// A real *store.Store must satisfy poller.Store without an adapter, so Run
// can be given one directly.
var _ poller.Store = (*store.Store)(nil)

// TestNewStatusIsZeroValue checks that a freshly constructed Poller
// reports a zero Status before Run has ever been called, so a caller
// wiring up the status endpoint sees an honest "nothing yet" rather than a
// fabricated success.
func TestNewStatusIsZeroValue(t *testing.T) {
	t.Parallel()
	p := poller.New(scriptedSource(nil), &fakeStore{}, 15*24*time.Hour)
	got := p.Status()
	want := poller.Status{}
	if got != want {
		t.Errorf("Status() on a new Poller = %+v, want the zero value", got)
	}
}
