package store_test

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

func TestRoundTripThroughCloseAndReopen(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")
	key := testKey('R')

	s, err := store.Open(ctx, path, key)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}

	want := cgm.Reading{
		Time:   time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC),
		MgDl:   137,
		Trend:  cgm.TrendFortyFiveDown,
		Source: "synthetic",
	}
	inserted, err := s.InsertCurrent(ctx, want)
	if err != nil {
		t.Fatalf("InsertCurrent: %v", err)
	}
	if !inserted {
		t.Fatal("InsertCurrent reported inserted=false for a new timestamp")
	}
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	reopened, err := store.Open(ctx, path, key)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	got, err := reopened.Range(ctx, store.RangeQuery{})
	if err != nil {
		t.Fatalf("Range: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("Range returned %d readings, want 1", len(got))
	}
	if !got[0].Time.Equal(want.Time) {
		t.Errorf("Time = %v, want %v", got[0].Time, want.Time)
	}
	if got[0].MgDl != want.MgDl {
		t.Errorf("MgDl = %d, want %d", got[0].MgDl, want.MgDl)
	}
	if got[0].Trend != want.Trend {
		t.Errorf("Trend = %v, want %v", got[0].Trend, want.Trend)
	}
	if got[0].Source != want.Source {
		t.Errorf("Source = %q, want %q", got[0].Source, want.Source)
	}
}

func TestOpenWithWrongKeyFails(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")

	right := testKey('A')
	wrong := testKey('B')

	s, err := store.Open(ctx, path, right)
	if err != nil {
		t.Fatalf("Open with right key: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	_, err = store.Open(ctx, path, wrong)
	if err == nil {
		t.Fatal("Open with wrong key succeeded, want an error")
	}
	if !errors.Is(err, store.ErrWrongKey) {
		t.Errorf("error = %v, want it to wrap store.ErrWrongKey", err)
	}
}

func TestOpenRejectsWrongKeyLength(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")

	_, err := store.Open(ctx, path, []byte("too-short"))
	if err == nil {
		t.Fatal("Open with a 9-byte key succeeded, want an error")
	}
}
