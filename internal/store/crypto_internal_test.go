package store

import (
	"bytes"
	"testing"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

func TestSealOpenBytesRoundTrip(t *testing.T) {
	key := bytes.Repeat([]byte{0x7A}, keySize)
	aad := aadForTimestamp(1234567890)
	plaintext := []byte("synthetic payload")

	sealed, err := sealBytes(key, aad, plaintext)
	if err != nil {
		t.Fatalf("sealBytes: %v", err)
	}
	if bytes.Contains(sealed, plaintext) {
		t.Fatal("sealed output contains the plaintext verbatim")
	}

	got, err := openBytes(key, aad, sealed)
	if err != nil {
		t.Fatalf("openBytes: %v", err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Errorf("openBytes = %q, want %q", got, plaintext)
	}
}

func TestOpenBytesRejectsWrongAAD(t *testing.T) {
	key := bytes.Repeat([]byte{0x7B}, keySize)
	sealed, err := sealBytes(key, aadForTimestamp(100), []byte("payload"))
	if err != nil {
		t.Fatalf("sealBytes: %v", err)
	}
	if _, err := openBytes(key, aadForTimestamp(200), sealed); err == nil {
		t.Error("openBytes with mismatched AAD succeeded, want an error")
	}
}

func TestOpenBytesRejectsWrongKey(t *testing.T) {
	right := bytes.Repeat([]byte{0x7C}, keySize)
	wrong := bytes.Repeat([]byte{0x7D}, keySize)
	aad := aadForTimestamp(300)

	sealed, err := sealBytes(right, aad, []byte("payload"))
	if err != nil {
		t.Fatalf("sealBytes: %v", err)
	}
	if _, err := openBytes(wrong, aad, sealed); err == nil {
		t.Error("openBytes with the wrong key succeeded, want an error")
	}
}

func TestEncodeDecodeValueRoundTrip(t *testing.T) {
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
	if _, _, err := decodeValue([]byte{1, 2, 3}); err == nil {
		t.Error("decodeValue with a 3-byte payload succeeded, want an error")
	}
}
