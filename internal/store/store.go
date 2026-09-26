// Package store persists CGM readings to a local SQLite database, sealing
// every value and trend with AES-256-GCM before it touches disk.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	_ "modernc.org/sqlite" // pure-Go SQLite driver; CGO stays disabled
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

// Store is an encrypted, on-disk reading store backed by SQLite. A Store
// must be closed with Close when the caller is done with it.
type Store struct {
	db  *sql.DB
	key []byte
}

// Open opens (creating if necessary) the SQLite database at path, sealing
// and opening reading values with key, which must be exactly 32 bytes (for
// AES-256). Open fails with ErrWrongKey if the database already exists and
// was created with a different key.
func Open(ctx context.Context, path string, key []byte) (*Store, error) {
	if len(key) != keySize {
		return nil, fmt.Errorf("store: key must be %d bytes, got %d", keySize, len(key))
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", path, err)
	}
	// A single connection serialises every statement, so writers never
	// contend for SQLite's lock.
	db.SetMaxOpenConns(1)

	if _, err := db.ExecContext(ctx, "PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("store: set journal mode: %w", err)
	}
	if _, err := db.ExecContext(ctx, schemaSQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("store: create schema: %w", err)
	}

	s := &Store{db: db, key: append([]byte(nil), key...)}
	if err := s.verifyOrSeedCheckValue(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

// verifyOrSeedCheckValue seals the fixed check value into a fresh database,
// or, if one is already stored, tries to open it with s.key and fails with
// ErrWrongKey if that does not work.
func (s *Store) verifyOrSeedCheckValue(ctx context.Context) error {
	var sealed []byte
	err := s.db.QueryRowContext(ctx, "SELECT sealed FROM check_value WHERE id = 1").Scan(&sealed)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		fresh, sealErr := sealBytes(s.key, checkValueAAD, checkValuePlaintext)
		if sealErr != nil {
			return fmt.Errorf("store: seal check value: %w", sealErr)
		}
		if _, execErr := s.db.ExecContext(ctx, "INSERT INTO check_value (id, sealed) VALUES (1, ?)", fresh); execErr != nil {
			return fmt.Errorf("store: seed check value: %w", execErr)
		}
		return nil
	case err != nil:
		return fmt.Errorf("store: read check value: %w", err)
	}

	if _, openErr := openBytes(s.key, checkValueAAD, sealed); openErr != nil {
		return fmt.Errorf("%w: %v", ErrWrongKey, openErr)
	}
	return nil
}

// Close releases the underlying database handle.
func (s *Store) Close() error {
	return s.db.Close()
}
