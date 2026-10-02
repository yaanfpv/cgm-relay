package nightscout_test

import (
	"crypto/sha1"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/yaanfpv/cgm-relay/internal/nightscout"
)

const testToken = "correct-token"

// wrongTokenSHA1Hex is the api-secret header value the wrong token would
// produce, so the "wrong credential" cases exercise a real, well-formed
// but incorrect SHA-1, rather than an obviously malformed header.
var wrongTokenSHA1Hex = sha1Hex("wrong-token")

func sha1Hex(s string) string {
	sum := sha1.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

// nightscoutEndpoints is every route the handler registers. Every one of
// them must refuse without a valid credential except the ones in
// openEndpoints, so the auth tests below run this exact list rather than a
// sample of it.
var nightscoutEndpoints = []string{
	"/",
	"/api/v1/entries/sgv.json",
	"/api/v1/entries.json",
	"/api/v1/entries/current.json",
	"/api/v1/status.json",
	"/api/v1/experiments/test",
	"/api/v1/treatments.json",
	"/api/v1/treatments",
	"/api/v1/devicestatus.json",
	"/api/v1/devicestatus",
	"/api/v1/profile",
	"/api/v1/profiles.json",
}

// openEndpoints are the only routes answered without a credential: the
// service-status check follower apps run without one, and the plain page
// opened from it.
var openEndpoints = map[string]bool{
	"/":                   true,
	"/api/v1/status.json": true,
}

// TestEveryEndpointRequiresAuth checks, across every registered endpoint
// other than the open ones, that no credential and a wrong credential in
// either accepted form both get 401, that the open ones answer 200 with
// either, and that the token query parameter and the api-secret header
// each independently let a request through when correct.
func TestEveryEndpointRequiresAuth(t *testing.T) {
	t.Parallel()
	for _, path := range nightscoutEndpoints {
		t.Run(path, func(t *testing.T) {
			refused := http.StatusUnauthorized
			if openEndpoints[path] {
				refused = http.StatusOK
			}
			h, err := nightscout.New(&fakeStore{}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}

			cases := []struct {
				name       string
				configure  func(r *http.Request)
				wantStatus int
			}{
				{"no credential", func(r *http.Request) {}, refused},
				{"wrong token query param", func(r *http.Request) {
					q := r.URL.Query()
					q.Set("token", "wrong-token")
					r.URL.RawQuery = q.Encode()
				}, refused},
				{"wrong api-secret header (wrong hash)", func(r *http.Request) {
					r.Header.Set("api-secret", wrongTokenSHA1Hex)
				}, refused},
				{"wrong api-secret header (wrong raw token)", func(r *http.Request) {
					r.Header.Set("api-secret", "wrong-token")
				}, refused},
				{"empty token query param", func(r *http.Request) {
					q := r.URL.Query()
					q.Set("token", "")
					r.URL.RawQuery = q.Encode()
				}, refused},
				{"token query param with a trailing space", func(r *http.Request) {
					r.URL.RawQuery = "token=" + testToken + "%20"
				}, http.StatusOK},
				{"token query param with a trailing newline", func(r *http.Request) {
					r.URL.RawQuery = "token=" + testToken + "%0A"
				}, http.StatusOK},
				{"token query param with a leading newline and a trailing CRLF", func(r *http.Request) {
					r.URL.RawQuery = "token=%0A" + testToken + "%0D%0A"
				}, http.StatusOK},
				{"token query param with a tab and a plus-encoded space", func(r *http.Request) {
					r.URL.RawQuery = "token=%09" + testToken + "+"
				}, http.StatusOK},
				{"wrong token with trailing whitespace", func(r *http.Request) {
					r.URL.RawQuery = "token=wrong-token%20"
				}, refused},
				{"token with whitespace inside", func(r *http.Request) {
					r.URL.RawQuery = "token=correct%20-token"
				}, refused},
				{"whitespace only token", func(r *http.Request) {
					r.URL.RawQuery = "token=%20%0A"
				}, refused},
				{"right api-secret header with surrounding whitespace, SHA-1 hex", func(r *http.Request) {
					r.Header.Set("api-secret", " "+sha1Hex(testToken)+"\t")
				}, http.StatusOK},
				{"right api-secret header with a trailing newline, raw token", func(r *http.Request) {
					r.Header.Set("api-secret", testToken+"\n")
				}, http.StatusOK},
				{"wrong api-secret header with trailing whitespace", func(r *http.Request) {
					r.Header.Set("api-secret", "wrong-token ")
				}, refused},
				{"right token query param", func(r *http.Request) {
					q := r.URL.Query()
					q.Set("token", testToken)
					r.URL.RawQuery = q.Encode()
				}, http.StatusOK},
				{"right api-secret header, SHA-1 hex of the token", func(r *http.Request) {
					r.Header.Set("api-secret", sha1Hex(testToken))
				}, http.StatusOK},
				{"right api-secret header, SHA-1 hex uppercased", func(r *http.Request) {
					r.Header.Set("api-secret", strings.ToUpper(sha1Hex(testToken)))
				}, http.StatusOK},
				{"right api-secret header, raw token", func(r *http.Request) {
					r.Header.Set("api-secret", testToken)
				}, http.StatusOK},
			}

			for _, c := range cases {
				t.Run(c.name, func(t *testing.T) {
					req := httptest.NewRequest(http.MethodGet, path, nil)
					c.configure(req)
					rec := httptest.NewRecorder()
					h.ServeHTTP(rec, req)
					if rec.Code != c.wantStatus {
						t.Errorf("status = %d, want %d (body: %s)", rec.Code, c.wantStatus, rec.Body.String())
					}
				})
			}
		})
	}
}
