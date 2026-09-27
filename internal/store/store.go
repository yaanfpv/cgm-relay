// Package store persists CGM readings to a local SQLite database, sealing
// every value and trend with AES-256-GCM before it touches disk.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	sqlite "modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

// schemaSQL creates the tables a fresh database needs. It is safe to run
// against an existing database: every statement is idempotent.
const schemaSQL = `
CREATE TABLE IF NOT EXISTS readings (
	ts     INTEGER NOT NULL UNIQUE,
	source TEXT    NOT NULL,
	sealed BLOB    NOT NULL
);
CREATE TABLE IF NOT EXISTS check_value (
	id     INTEGER PRIMARY KEY CHECK (id = 1),
	sealed BLOB NOT NULL
);
`

// ErrWrongKey is returned by Open when the supplied key cannot open the
// database's stored check value, meaning it is not the key the database
// was created with.
var ErrWrongKey = errors.New("store: wrong key")

// ErrDamaged is returned by Open when the file at path exists but SQLite
// cannot read it as a database at all: corrupted, truncated, or never a
// SQLite file to begin with. Unlike an ordinary I/O error, this is
// permanent -- opening the same path again will not help -- so it is
// reported apart from every other failure Open can return.
var ErrDamaged = errors.New("store: database file is damaged")

// Store is an encrypted, on-disk reading store backed by SQLite. A Store
// must be closed with Close when the caller is done with it.
type Store struct {
	db   *sql.DB
	key  []byte
	lock *dbLock
}

// Open opens (creating if necessary) the SQLite database at path, sealing
// and opening reading values with key, which must be exactly 32 bytes (for
// AES-256). Before touching the database at all, Open takes an exclusive
// lock on a file beside it, so a second process pointed at the same path
// -- a second copy of the app, most likely -- fails with ErrInUse rather
// than racing this one for the same file. Open fails with ErrWrongKey if
// the database already exists and was created with a different key, and
// with ErrDamaged if SQLite cannot read the file as a database at all.
func Open(ctx context.Context, path string, key []byte) (*Store, error) {
	if len(key) != keySize {
		return nil, fmt.Errorf("store: key must be %d bytes, got %d", keySize, len(key))
	}

	lock, err := acquireLock(path)
	if err != nil {
		return nil, err
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		lock.release()
		return nil, fmt.Errorf("store: open %s: %w", path, err)
	}
	// A single connection serialises every statement, so writers never
	// contend for SQLite's lock.
	db.SetMaxOpenConns(1)

	if _, err := db.ExecContext(ctx, "PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		lock.release()
		return nil, classifyOpenError(path, fmt.Errorf("store: set journal mode: %w", err))
	}
	if _, err := db.ExecContext(ctx, schemaSQL); err != nil {
		db.Close()
		lock.release()
		return nil, classifyOpenError(path, fmt.Errorf("store: create schema: %w", err))
	}

	s := &Store{db: db, key: append([]byte(nil), key...), lock: lock}
	if err := s.verifyOrSeedCheckValue(ctx, path); err != nil {
		db.Close()
		lock.release()
		return nil, err
	}
	return s, nil
}

// classifyOpenError wraps err from a failed step in Open with ErrDamaged
// when SQLite's own error code says the file is not a database at all or
// its image is corrupt (SQLITE_NOTADB, SQLITE_CORRUPT), and returns err
// unchanged for every other cause. The primary result code is checked
// (masking off SQLite's extended-code bits) since SQLite reports several
// distinct extended codes for a corrupt image depending on which page it
// tripped over.
func classifyOpenError(path string, err error) error {
	var sqliteErr *sqlite.Error
	if errors.As(err, &sqliteErr) {
		switch sqliteErr.Code() & 0xff {
		case sqlite3.SQLITE_NOTADB, sqlite3.SQLITE_CORRUPT:
			return fmt.Errorf("%w: %s: %v", ErrDamaged, path, err)
		}
	}
	return err
}

// verifyOrSeedCheckValue seals the fixed check value into a fresh database,
// or, if one is already stored, tries to open it with s.key and fails with
// ErrWrongKey if that does not work. Reading or writing that one row is the
// step where a page corrupt anywhere other than the schema itself first
// surfaces, so both its failure paths go through classifyOpenError exactly
// like the journal-mode and schema steps in Open above.
func (s *Store) verifyOrSeedCheckValue(ctx context.Context, path string) error {
	var sealed []byte
	err := s.db.QueryRowContext(ctx, "SELECT sealed FROM check_value WHERE id = 1").Scan(&sealed)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		fresh, sealErr := sealBytes(s.key, checkValueAAD, checkValuePlaintext)
		if sealErr != nil {
			return fmt.Errorf("store: seal check value: %w", sealErr)
		}
		if _, execErr := s.db.ExecContext(ctx, "INSERT INTO check_value (id, sealed) VALUES (1, ?)", fresh); execErr != nil {
			return classifyOpenError(path, fmt.Errorf("store: seed check value: %w", execErr))
		}
		return nil
	case err != nil:
		return classifyOpenError(path, fmt.Errorf("store: read check value: %w", err))
	}

	if _, openErr := openBytes(s.key, checkValueAAD, sealed); openErr != nil {
		return fmt.Errorf("%w: %v", ErrWrongKey, openErr)
	}
	return nil
}

// Close releases the underlying database handle and the lock Open took on
// it, in that order, so another process waiting on the lock never sees it
// released while a write might still be in flight.
func (s *Store) Close() error {
	dbErr := s.db.Close()
	lockErr := s.lock.release()
	if dbErr != nil {
		return dbErr
	}
	return lockErr
}
