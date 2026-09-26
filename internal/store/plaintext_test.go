package store_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/binary"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// TestNoPlaintextOnDisk stores readings with distinctive values, closes the
// store, and then scans every file the store created (the main database
// file plus whatever WAL/journal/shm files SQLite left behind) for a
// plaintext encoding of those values. It also confirms two rows carrying
// the same value and trend still produce different ciphertexts, which is
// what a fresh random nonce per row buys.
func TestNoPlaintextOnDisk(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	path := filepath.Join(dir, "readings.db")
	key := testKey('P')

	s, err := store.Open(ctx, path, key)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}

	const markerA = 823401 // distinctive, synthetic mg/dL value
	const markerB = 741852 // a second, distinct value
	base := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)

	readings := []cgm.Reading{
		{Time: base, MgDl: markerA, Trend: cgm.TrendFlat, Source: "synthetic"},
		{Time: base.Add(time.Hour), MgDl: markerA, Trend: cgm.TrendFlat, Source: "synthetic"},
		{Time: base.Add(2 * time.Hour), MgDl: markerB, Trend: cgm.TrendSingleUp, Source: "synthetic"},
	}
	for _, r := range readings {
		if _, err := s.InsertCurrent(ctx, r); err != nil {
			t.Fatalf("InsertCurrent: %v", err)
		}
	}

	sealed := readSealedColumn(t, path)
	if len(sealed) != len(readings) {
		t.Fatalf("stored %d rows, want %d", len(sealed), len(readings))
	}
	ctA := sealed[readings[0].Time.Unix()]
	ctA2 := sealed[readings[1].Time.Unix()]
	if len(ctA) == 0 || len(ctA2) == 0 {
		t.Fatal("expected sealed ciphertext for both equal-value rows")
	}
	if bytes.Equal(ctA, ctA2) {
		t.Error("two rows storing the same value and trend produced identical ciphertext")
	}

	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	var forms [][]byte
	forms = append(forms, plaintextForms(markerA)...)
	forms = append(forms, plaintextForms(markerB)...)

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) == 0 {
		t.Fatal("store created no files in its directory")
	}
	for _, entry := range entries {
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", entry.Name(), err)
		}
		for _, form := range forms {
			if bytes.Contains(data, form) {
				t.Errorf("file %s contains a plaintext encoding of a stored value (%x)", entry.Name(), form)
			}
		}
	}
}

// readSealedColumn opens path directly with the raw SQLite driver, bypassing
// Store's own decryption, and returns each row's sealed bytes keyed by
// timestamp.
func readSealedColumn(t *testing.T, path string) map[int64][]byte {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open raw db: %v", err)
	}
	defer db.Close()

	rows, err := db.Query("SELECT ts, sealed FROM readings")
	if err != nil {
		t.Fatalf("query sealed column: %v", err)
	}
	defer rows.Close()

	out := map[int64][]byte{}
	for rows.Next() {
		var ts int64
		var sealed []byte
		if err := rows.Scan(&ts, &sealed); err != nil {
			t.Fatalf("scan raw row: %v", err)
		}
		out[ts] = sealed
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("raw rows: %v", err)
	}
	return out
}

// plaintextForms returns the byte patterns a plaintext leak of v would show
// up as: its decimal text, and 4-byte/8-byte big- and little-endian binary
// encodings. Shorter binary widths are skipped deliberately: a 1- or 2-byte
// pattern is so short it turns up by pure chance inside any nontrivial
// stretch of ciphertext, which would make the test flag noise instead of a
// real leak.
func plaintextForms(v int) [][]byte {
	forms := [][]byte{[]byte(strconv.Itoa(v))}
	u := uint64(int64(v))

	be4, le4 := make([]byte, 4), make([]byte, 4)
	binary.BigEndian.PutUint32(be4, uint32(u))
	binary.LittleEndian.PutUint32(le4, uint32(u))

	be8, le8 := make([]byte, 8), make([]byte, 8)
	binary.BigEndian.PutUint64(be8, u)
	binary.LittleEndian.PutUint64(le8, u)

	return append(forms, be4, le4, be8, le8)
}
