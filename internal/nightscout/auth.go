package nightscout

import (
	"crypto/sha1"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"strings"
)

// checkAuth reports whether r carries a valid credential: either the raw
// token as a "token" query parameter, or an "api-secret" header equal to
// the hex-encoded SHA-1 of the token. Both forms are compared in constant
// time, so neither leaks how much of the credential a caller got right.
func (h *handler) checkAuth(r *http.Request) bool {
	if token := r.URL.Query().Get("token"); token != "" && constantTimeEqual(token, h.token) {
		return true
	}
	if secret := r.Header.Get("api-secret"); secret != "" && constantTimeEqual(strings.ToLower(secret), h.tokenSHA1Hex) {
		return true
	}
	return false
}

// constantTimeEqual reports whether a and b hold the same bytes, taking
// time independent of where they first differ. subtle.ConstantTimeCompare
// itself rejects mismatched lengths before the constant-time loop runs,
// which leaks only the length of the caller's guess, never its content.
func constantTimeEqual(a, b string) bool {
	return len(a) == len(b) && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// sha1Hex returns the lowercase hex-encoded SHA-1 digest of s, matching the
// api-secret header format Nightscout follower apps send (e.g. xDrip4iOS's
// String.sha1()).
func sha1Hex(s string) string {
	sum := sha1.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}
