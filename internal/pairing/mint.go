package pairing

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"time"
)

// maxMintBody bounds the request body the mint route reads.
const maxMintBody = 32 << 10

type mintRequest struct {
	Apps []App `json:"apps"`
}

type mintResponse struct {
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expires_at"`
}

// MintHandler serves POST: it mints a pairing code that shows the apps in
// the JSON body ({"apps": [...]}, see App) and answers
// {"code": ..., "expires_at": ...}. It belongs on the loopback-only status
// listener only; on top of that it refuses any request whose peer address
// is not loopback, and any body that is not JSON, which a web page cannot
// send cross-origin without a preflight the relay never answers.
func MintHandler(store *Store) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !isLoopbackPeer(r.RemoteAddr) {
			http.Error(w, "pairing: codes are minted from this Mac only", http.StatusForbidden)
			return
		}
		if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
			http.Error(w, "pairing: request body must be application/json", http.StatusUnsupportedMediaType)
			return
		}
		// The whole body is read under the bound first, so an over-limit body
		// is refused whatever its prefix says, and then decoded as exactly one
		// object: unknown fields refused, nothing but whitespace after it.
		raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxMintBody))
		if err != nil {
			var tooBig *http.MaxBytesError
			if errors.As(err, &tooBig) {
				http.Error(w, "pairing: request body is too large", http.StatusRequestEntityTooLarge)
				return
			}
			http.Error(w, "pairing: malformed request", http.StatusBadRequest)
			return
		}
		var req mintRequest
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&req); err != nil || dec.More() {
			http.Error(w, "pairing: malformed request", http.StatusBadRequest)
			return
		}
		if _, err := dec.Token(); err != io.EOF {
			http.Error(w, "pairing: malformed request", http.StatusBadRequest)
			return
		}
		code, expires, err := store.Mint(req.Apps)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(mintResponse{Code: code, ExpiresAt: expires.UTC()})
	})
}

func isLoopbackPeer(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
