package store_test

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

func TestRoundTripThroughCloseAndReopen(t *testing.T) {
	t.Parallel()
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
	result, err := s.StorePoll(ctx, nil, &want)
	if err != nil {
		t.Fatalf("StorePoll: %v", err)
	}
	if result.Current == nil || result.Current.Outcome != store.PollStored {
		t.Fatalf("StorePoll current outcome = %+v, want PollStored", result.Current)
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
	t.Parallel()
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
	t.Parallel()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")

	_, err := store.Open(ctx, path, []byte("too-short"))
	if err == nil {
		t.Fatal("Open with a 9-byte key succeeded, want an error")
	}
}

// TestOpenWhileAlreadyOpenReturnsErrInUse proves a second process pointed
// at the same database path -- a second copy of the app, most likely --
// gets a distinct, documented error rather than racing the first for the
// same file underneath SQLite.
func TestOpenWhileAlreadyOpenReturnsErrInUse(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")
	key := testKey('L')

	first, err := store.Open(ctx, path, key)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	defer first.Close()

	_, err = store.Open(ctx, path, key)
	if err == nil {
		t.Fatal("second Open while the first is still open succeeded, want an error")
	}
	if !errors.Is(err, store.ErrInUse) {
		t.Errorf("error = %v, want it to wrap store.ErrInUse", err)
	}
}

// TestOpenAfterCloseReleasesTheLock proves Close releases the exclusive
// lock Open took, so a database can be reopened once the first user is
// done with it -- the ordinary reopen-after-close case, not just a crash.
func TestOpenAfterCloseReleasesTheLock(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")
	key := testKey('M')

	first, err := store.Open(ctx, path, key)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	second, err := store.Open(ctx, path, key)
	if err != nil {
		t.Fatalf("Open after Close: %v, want the released lock to let a fresh Open succeed", err)
	}
	if err := second.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
}

// TestFailedOpenReleasesTheLock proves a failed Open -- the wrong key,
// here -- never leaves the lock file held, so a caller retrying with the
// right key is not blocked by its own earlier failed attempt.
func TestFailedOpenReleasesTheLock(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")
	right := testKey('N')
	wrong := testKey('O')

	seeded, err := store.Open(ctx, path, right)
	if err != nil {
		t.Fatalf("seed Open: %v", err)
	}
	if err := seeded.Close(); err != nil {
		t.Fatalf("close seeded store: %v", err)
	}

	if _, err := store.Open(ctx, path, wrong); !errors.Is(err, store.ErrWrongKey) {
		t.Fatalf("Open with wrong key: %v, want store.ErrWrongKey", err)
	}

	recovered, err := store.Open(ctx, path, right)
	if err != nil {
		t.Fatalf("Open after a failed Open: %v, want the failed attempt's lock released", err)
	}
	if err := recovered.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
}

// TestOpenDamagedFileReturnsErrDamaged proves a file that exists but is
// not a readable SQLite database at all -- random bytes, here, the same
// shape a truncated or corrupted readings.db would take -- is reported as
// ErrDamaged rather than the generic error an ordinary I/O failure would
// produce.
func TestOpenDamagedFileReturnsErrDamaged(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")
	if err := os.WriteFile(path, bytes.Repeat([]byte{0xFF}, 512), 0o600); err != nil {
		t.Fatalf("write garbage file: %v", err)
	}

	_, err := store.Open(ctx, path, testKey('P'))
	if err == nil {
		t.Fatal("Open on a garbage file succeeded, want an error")
	}
	if !errors.Is(err, store.ErrDamaged) {
		t.Errorf("error = %v, want it to wrap store.ErrDamaged", err)
	}
}

// TestOpenWithCorruptCheckValuePageReturnsErrDamaged proves a database
// that is a perfectly readable SQLite file up through its schema, but
// whose check_value table's own page is corrupt, is still reported as
// ErrDamaged -- not the ordinary crash a corrupt page below the schema
// would otherwise fall through as, which would bring back the endless
// restart ErrDamaged exists to remove, for a database instead of a page.
func TestOpenWithCorruptCheckValuePageReturnsErrDamaged(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "readings.db")
	key := testKey('Q')

	seeded, err := store.Open(ctx, path, key)
	if err != nil {
		t.Fatalf("seed Open: %v", err)
	}
	if err := seeded.Close(); err != nil {
		t.Fatalf("close seeded store: %v", err)
	}

	// Find exactly where check_value's own data lives, and how big a page
	// is, from the database's own schema -- rather than assuming a page
	// number or a page size -- then overwrite only that one page. Page 1
	// (holding the schema itself) and every other table's page are left
	// alone, so journal_mode and schema creation on reopen still succeed;
	// only the read this test targets should fail.
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open raw connection: %v", err)
	}
	if _, err := raw.ExecContext(ctx, "PRAGMA wal_checkpoint(TRUNCATE)"); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}
	var pageSize, rootPage int64
	if err := raw.QueryRowContext(ctx, "PRAGMA page_size").Scan(&pageSize); err != nil {
		t.Fatalf("read page_size: %v", err)
	}
	if err := raw.QueryRowContext(ctx, "SELECT rootpage FROM sqlite_master WHERE name = 'check_value'").Scan(&rootPage); err != nil {
		t.Fatalf("read check_value's rootpage: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("close raw connection: %v", err)
	}

	f, err := os.OpenFile(path, os.O_RDWR, 0o600)
	if err != nil {
		t.Fatalf("open database file: %v", err)
	}
	garbage := bytes.Repeat([]byte{0xFF}, int(pageSize))
	if _, err := f.WriteAt(garbage, (rootPage-1)*pageSize); err != nil {
		t.Fatalf("overwrite check_value's page: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close database file: %v", err)
	}

	_, err = store.Open(ctx, path, key)
	if err == nil {
		t.Fatal("Open with a corrupt check_value page succeeded, want an error")
	}
	if !errors.Is(err, store.ErrDamaged) {
		t.Errorf("error = %v, want it to wrap store.ErrDamaged", err)
	}
}
