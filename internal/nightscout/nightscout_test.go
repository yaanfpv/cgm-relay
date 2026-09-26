package nightscout_test

import (
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/nightscout"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// A real *store.Store must keep satisfying nightscout.ReadingRange, since
// that is the whole reason the interface exists: to let this package be
// wired to the real store without either package depending on the other's
// concrete type beyond this one method.
var _ nightscout.ReadingRange = (*store.Store)(nil)

// TestNewRejectsEmptyToken checks that a handler cannot be built without
// a token, because a handler with no token would serve readings to anyone
// who could reach it.
func TestNewRejectsEmptyToken(t *testing.T) {
	h, err := nightscout.New(&fakeStore{}, "", nil)
	if err == nil {
		t.Fatal("New with an empty token returned no error, want one")
	}
	if h != nil {
		t.Error("New with an empty token returned a non-nil handler, want nil")
	}
}

// TestNewRejectsNilReadings checks that New refuses a nil ReadingRange
// rather than building a handler that would panic on its first request.
func TestNewRejectsNilReadings(t *testing.T) {
	h, err := nightscout.New(nil, "s3cr3t", nil)
	if err == nil {
		t.Fatal("New with a nil ReadingRange returned no error, want one")
	}
	if h != nil {
		t.Error("New with a nil ReadingRange returned a non-nil handler, want nil")
	}
}

// TestNewAcceptsNilClock checks that a nil clock is tolerated (New falls
// back to time.Now) rather than the handler panicking on its first call to
// an endpoint that reports the time.
func TestNewAcceptsNilClock(t *testing.T) {
	if _, err := nightscout.New(&fakeStore{}, "s3cr3t", nil); err != nil {
		t.Fatalf("New with a nil clock: %v", err)
	}
}

// fixedClock returns a nightscout.Clock that always reports t, for tests
// that assert on a status response's reported server time.
func fixedClock(t time.Time) nightscout.Clock {
	return func() time.Time { return t }
}
