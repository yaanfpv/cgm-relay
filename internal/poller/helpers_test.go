package poller_test

import (
	"testing"
	"time"
)

// waitDone blocks for done to produce a value, failing the test if that
// takes more than a second. Every test calls it right after cancelling a
// Poller's context, so the bound also proves Run returned promptly.
func waitDone(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(time.Second):
		t.Fatal("Run did not return within 1s of cancellation")
		return nil
	}
}
