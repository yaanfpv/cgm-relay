package store_test

import (
	"bytes"
	"context"
	"path/filepath"
	"testing"

	"github.com/yaanfpv/cgm-relay/internal/store"
)

// testKey returns a distinct, deterministic 32-byte AES-256 key filled with
// b, so different tests can use different keys without needing real
// randomness.
func testKey(b byte) []byte {
	return bytes.Repeat([]byte{b}, 32)
}

// openTemp opens a fresh store backed by a database in t.TempDir(), using
// testKey('K'), and registers it to close when the test ends.
func openTemp(t *testing.T, ctx context.Context) (*store.Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "readings.db")
	s, err := store.Open(ctx, path, testKey('K'))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() {
		if err := s.Close(); err != nil {
			t.Errorf("store.Close: %v", err)
		}
	})
	return s, path
}
