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
	_, accepted := h.credentials(r, false)
	return accepted
}

// statusPath is the one route answered without a credential that still
// refuses a wrong one, so a follower app's connection check reports a
// mistyped token at setup.
const statusPath = "/api/v1/status.json"

// statusRefuses reports whether a request to status.json presents at least
// one credential and every one it presents is wrong. A request that presents
// none, or any right one, is answered. A Bearer token counts here and on no
// other route.
func (h *handler) statusRefuses(r *http.Request) bool {
	presented, accepted := h.credentials(r, true)
	return presented && !accepted
}

// credentials reports whether r presents any credential (a non-blank token
// query, api-secret header or, with bearer set, Bearer token) and whether any
// presented one is right. A blank value counts as not presented. A credential
// repeated in the query or as several header lines is read occurrence by
// occurrence, so a blank or wrong one never hides a right one after it, nor
// a blank one a wrong one. Every value is compared, whether or not an earlier
// one already matched.
func (h *handler) credentials(r *http.Request, bearer bool) (presented, accepted bool) {
	for _, value := range r.URL.Query()["token"] {
		if token := trimCredential(value); token != "" {
			presented = true
			accepted = constantTimeEqual(token, h.token) || accepted
		}
	}
	for _, value := range r.Header.Values("api-secret") {
		if secret := trimCredential(value); secret != "" {
			presented = true
			sha := constantTimeEqual(strings.ToLower(secret), h.tokenSHA1Hex)
			raw := constantTimeEqual(secret, h.token)
			accepted = sha || raw || accepted
		}
	}
	if bearer {
		for _, value := range r.Header.Values("Authorization") {
			if token := bearerToken(value); token != "" {
				presented = true
				accepted = constantTimeEqual(token, h.token) || accepted
			}
		}
	}
	return presented, accepted
}

// bearerToken returns the trimmed token of an "Authorization: Bearer"
// header value, or "" when it is not one. The scheme name is
// case-insensitive.
func bearerToken(value string) string {
	scheme, token, ok := strings.Cut(strings.TrimSpace(value), " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return ""
	}
	return trimCredential(token)
}

// unauthorizedBody is the answer Nightscout itself gives a request without a
// valid credential, so a follower app that parses the refusal reads the same
// fields it would read from Nightscout.
const unauthorizedBody = `{"status":401,"message":"Unauthorized","description":"Invalid/Missing"}` + "\n"

// writeUnauthorized answers 401 with Nightscout's JSON refusal. Every
// request that fails checkAuth is answered through it.
func writeUnauthorized(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(unauthorizedBody))
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
