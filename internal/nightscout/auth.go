package nightscout

import (
	"crypto/sha1"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"strings"
)

// checkAuth reports whether r carries a valid credential, in any of the
// three forms Nightscout follower apps send: the raw token as a "token"
// query parameter (xDrip4iOS, LoopFollow, Nightguard when no API secret is
// configured), an "api-secret" header holding the hex-encoded SHA-1 of the
// token (xDrip4iOS, xDrip+), or an "api-secret" header holding the raw
// token itself (Nightguard's legacy v1 requests, per its own comment that
// cgm-remote-monitor accepts an access token there). Every comparison is
// constant-time, so neither leaks how much of the credential a caller got
// right; the SHA-1 form is compared case-insensitively since hex digests
// arrive in both cases across these apps. Surrounding whitespace on the
// query value or the header is ignored.
func (h *handler) checkAuth(r *http.Request) bool {
	if token := trimCredential(r.URL.Query().Get("token")); token != "" && constantTimeEqual(token, h.token) {
		return true
	}
	if secret := trimCredential(r.Header.Get("api-secret")); secret != "" {
		if constantTimeEqual(strings.ToLower(secret), h.tokenSHA1Hex) {
			return true
		}
		if constantTimeEqual(secret, h.token) {
			return true
		}
	}
	return false
}

// trimCredential drops the ASCII whitespace (space, tab, CR, LF) a copied
// credential picks up on its way through a text editor, a chat message or
// a phone's paste box. The token alphabet is base64url, so none of it is
// ever part of a real credential.
func trimCredential(s string) string {
	return strings.Trim(s, " \t\r\n")
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
