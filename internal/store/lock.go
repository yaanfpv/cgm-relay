package store

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// lockSuffix names a database's own lock file, appended to its full path:
// the file holds no data and is never read, only flocked. macOS's
// DatabaseRecovery.swift takes the same lock, at this same suffix, before
// moving a database aside, so the two must always agree.
const lockSuffix = ".lock"

// ErrInUse is returned by Open when another process already holds the
// exclusive lock on path's own lock file -- a second copy of this program
// pointed at the same database, most likely.
var ErrInUse = errors.New("store: database is in use by another process")

// dbLock is an exclusive, advisory flock on a database's own lock file,
// held for as long as the file descriptor stays open. The lock is
// released the instant the descriptor closes -- an explicit release, or
// the process exiting for any reason, crash included -- so a process that
// never shuts down cleanly can never leave the database looking
// permanently in use.
type dbLock struct {
	f *os.File
}

// acquireLock takes an exclusive, non-blocking flock on databasePath's own
// lock file, creating the file if it does not already exist. It returns
// ErrInUse if another process already holds it.
func acquireLock(databasePath string) (*dbLock, error) {
	path := databasePath + lockSuffix
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("store: open lock file %s: %w", path, err)
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, fmt.Errorf("%w: %s", ErrInUse, path)
		}
		return nil, fmt.Errorf("store: lock %s: %w", path, err)
	}
	return &dbLock{f: f}, nil
}

// release releases the flock and closes its file descriptor. The lock
// file itself is left in place: acquireLock only ever needs to reopen it,
// and removing it would race a second process that just created it.
func (l *dbLock) release() error {
	return l.f.Close()
}
