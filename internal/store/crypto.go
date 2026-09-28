package store

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

// keySize is the required length of the caller-supplied encryption key, for
// AES-256.
const keySize = 32

// checkValueAAD binds the stored check value's ciphertext to its own role,
// so it can never be swapped in for a reading row's sealed payload.
var checkValueAAD = []byte("cgm-relay/check-value/v1")

// checkValuePlaintext is the fixed plaintext sealed into the check_value
// row at first Open. A later Open reseals nothing; it just tries to open
// this same row with the caller's key and fails loudly if that key is wrong.
var checkValuePlaintext = []byte("cgm-relay-store-check-v1")

// sealWithAEAD seals plaintext under gcm, binding it to aad, and returns
// nonce||ciphertext. A fresh random nonce is generated per call; every
// *Store method shares one long-lived cipher.AEAD instance rather than
// building a fresh one per call.
func sealWithAEAD(gcm cipher.AEAD, aad, plaintext []byte) ([]byte, error) {
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("store: generate nonce: %w", err)
	}
	sealed := gcm.Seal(nonce, nonce, plaintext, aad)
	return sealed, nil
}

// openWithAEAD reverses sealWithAEAD: it splits sealed into its nonce and
// ciphertext, then authenticates and decrypts against aad using gcm. It
// fails if gcm's key, aad, or sealed does not match what sealWithAEAD
// produced.
func openWithAEAD(gcm cipher.AEAD, aad, sealed []byte) ([]byte, error) {
	if len(sealed) < gcm.NonceSize() {
		return nil, fmt.Errorf("store: sealed payload too short: %d bytes", len(sealed))
	}
	nonce, ciphertext := sealed[:gcm.NonceSize()], sealed[gcm.NonceSize():]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, fmt.Errorf("store: open sealed payload: %w", err)
	}
	return plaintext, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	if len(key) != keySize {
		return nil, fmt.Errorf("store: key must be %d bytes, got %d", keySize, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("store: create cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("store: create gcm: %w", err)
	}
	return gcm, nil
}

// aadForTimestamp binds a reading row's sealed value to its own timestamp,
// so its ciphertext cannot be moved to another row.
func aadForTimestamp(unixSeconds int64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, uint64(unixSeconds))
	return b
}

// valuePayloadSize is the fixed encoded size of a reading's value and
// trend: a 4-byte mg/dL value plus a 1-byte trend code.
const valuePayloadSize = 5

// encodeValue packs mgDl and trend into the fixed-size plaintext that gets
// sealed into a reading row.
func encodeValue(mgDl int, trend cgm.Trend) []byte {
	buf := make([]byte, valuePayloadSize)
	binary.BigEndian.PutUint32(buf[0:4], uint32(int32(mgDl)))
	buf[4] = byte(trend)
	return buf
}

// decodeValue reverses encodeValue.
func decodeValue(b []byte) (mgDl int, trend cgm.Trend, err error) {
	if len(b) != valuePayloadSize {
		return 0, 0, fmt.Errorf("store: unexpected value payload length %d, want %d", len(b), valuePayloadSize)
	}
	mgDl = int(int32(binary.BigEndian.Uint32(b[0:4])))
	trend = cgm.Trend(b[4])
	return mgDl, trend, nil
}
