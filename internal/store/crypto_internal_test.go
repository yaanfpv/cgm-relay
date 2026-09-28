package store

import (
	"bytes"
	"sync"
	"testing"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

func TestSealOpenBytesRoundTrip(t *testing.T) {
	t.Parallel()
	key := bytes.Repeat([]byte{0x7A}, keySize)
	gcm, err := newGCM(key)
	if err != nil {
		t.Fatalf("newGCM: %v", err)
	}
	aad := aadForTimestamp(1234567890)
	plaintext := []byte("synthetic payload")

	sealed, err := sealWithAEAD(gcm, aad, plaintext)
	if err != nil {
		t.Fatalf("sealWithAEAD: %v", err)
	}
	if bytes.Contains(sealed, plaintext) {
		t.Fatal("sealed output contains the plaintext verbatim")
	}

	got, err := openWithAEAD(gcm, aad, sealed)
	if err != nil {
		t.Fatalf("openWithAEAD: %v", err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Errorf("openWithAEAD = %q, want %q", got, plaintext)
	}
}

func TestOpenBytesRejectsWrongAAD(t *testing.T) {
	t.Parallel()
	key := bytes.Repeat([]byte{0x7B}, keySize)
	gcm, err := newGCM(key)
	if err != nil {
		t.Fatalf("newGCM: %v", err)
	}
	sealed, err := sealWithAEAD(gcm, aadForTimestamp(100), []byte("payload"))
	if err != nil {
		t.Fatalf("sealWithAEAD: %v", err)
	}
	if _, err := openWithAEAD(gcm, aadForTimestamp(200), sealed); err == nil {
		t.Error("openWithAEAD with mismatched AAD succeeded, want an error")
	}
}

func TestOpenBytesRejectsWrongKey(t *testing.T) {
	t.Parallel()
	right := bytes.Repeat([]byte{0x7C}, keySize)
	wrong := bytes.Repeat([]byte{0x7D}, keySize)
	aad := aadForTimestamp(300)

	rightGCM, err := newGCM(right)
	if err != nil {
		t.Fatalf("newGCM(right): %v", err)
	}
	wrongGCM, err := newGCM(wrong)
	if err != nil {
		t.Fatalf("newGCM(wrong): %v", err)
	}

	sealed, err := sealWithAEAD(rightGCM, aad, []byte("payload"))
	if err != nil {
		t.Fatalf("sealWithAEAD: %v", err)
	}
	if _, err := openWithAEAD(wrongGCM, aad, sealed); err == nil {
		t.Error("openWithAEAD with the wrong key succeeded, want an error")
	}
}

func TestEncodeDecodeValueRoundTrip(t *testing.T) {
	t.Parallel()
	cases := []struct {
		mgDl  int
		trend cgm.Trend
	}{
		{0, cgm.TrendUnknown},
		{40, cgm.TrendDoubleDown},
		{400, cgm.TrendDoubleUp},
		{137, cgm.TrendFlat},
	}
	for _, c := range cases {
		encoded := encodeValue(c.mgDl, c.trend)
		gotMgDl, gotTrend, err := decodeValue(encoded)
		if err != nil {
			t.Fatalf("decodeValue(%d, %v): %v", c.mgDl, c.trend, err)
		}
		if gotMgDl != c.mgDl || gotTrend != c.trend {
			t.Errorf("round trip (%d, %v) = (%d, %v)", c.mgDl, c.trend, gotMgDl, gotTrend)
		}
	}
}

func TestDecodeValueRejectsWrongLength(t *testing.T) {
	t.Parallel()
	if _, _, err := decodeValue([]byte{1, 2, 3}); err == nil {
		t.Error("decodeValue with a 3-byte payload succeeded, want an error")
	}
}

// TestCipherConcurrentSealOpen hammers one shared cipher.AEAD with
// concurrent Seal and Open calls, mirroring the real shape of a *Store's
// use of its own cached instance: the poller sealing fresh rows while an
// HTTP handler opens rows sealed earlier, all against the same instance
// at the same time. Every round trip must still decrypt to exactly what
// was sealed, run under -race, proving the cached cipher.AEAD carries no
// mutable state a concurrent caller can corrupt.
func TestCipherConcurrentSealOpen(t *testing.T) {
	t.Parallel()
	key := make([]byte, keySize)
	for i := range key {
		key[i] = byte(i)
	}
	gcm, err := newGCM(key)
	if err != nil {
		t.Fatalf("newGCM: %v", err)
	}

	// Seed the rows opened concurrently before the timed section, so a
	// reader and a writer are never racing over the same slice slot --
	// only over gcm itself, which is the thing this test exists to check.
	const preSealed = 32
	seededSealed := make([][]byte, preSealed)
	for i := range seededSealed {
		sealed, err := sealWithAEAD(gcm, aadForTimestamp(int64(i)), encodeValue(80+i, cgm.Trend(i%6)))
		if err != nil {
			t.Fatalf("seed sealWithAEAD[%d]: %v", i, err)
		}
		seededSealed[i] = sealed
	}

	var wg sync.WaitGroup

	// Half the goroutines open the pre-seeded rows...
	for i := 0; i < preSealed; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			plaintext, err := openWithAEAD(gcm, aadForTimestamp(int64(i)), seededSealed[i])
			if err != nil {
				t.Errorf("openWithAEAD[%d]: %v", i, err)
				return
			}
			mgDl, trend, err := decodeValue(plaintext)
			if err != nil {
				t.Errorf("decodeValue[%d]: %v", i, err)
				return
			}
			if want := 80 + i; mgDl != want {
				t.Errorf("row %d: MgDl = %d, want %d", i, mgDl, want)
			}
			if want := cgm.Trend(i % 6); trend != want {
				t.Errorf("row %d: Trend = %v, want %v", i, trend, want)
			}
		}()
	}

	// ...while the other half seal brand new ones, concurrently, against
	// the same shared instance.
	const newRows = 32
	for i := 0; i < newRows; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			ts := int64(preSealed + i)
			plaintext := encodeValue(150+i, cgm.Trend(i%6))
			sealed, err := sealWithAEAD(gcm, aadForTimestamp(ts), plaintext)
			if err != nil {
				t.Errorf("sealWithAEAD[%d]: %v", ts, err)
				return
			}
			got, err := openWithAEAD(gcm, aadForTimestamp(ts), sealed)
			if err != nil {
				t.Errorf("round-trip openWithAEAD[%d]: %v", ts, err)
				return
			}
			mgDl, trend, err := decodeValue(got)
			if err != nil {
				t.Errorf("round-trip decodeValue[%d]: %v", ts, err)
				return
			}
			if want := 150 + i; mgDl != want {
				t.Errorf("row %d: MgDl = %d, want %d", ts, mgDl, want)
			}
			if want := cgm.Trend(i % 6); trend != want {
				t.Errorf("row %d: Trend = %v, want %v", ts, trend, want)
			}
		}()
	}

	wg.Wait()
}
