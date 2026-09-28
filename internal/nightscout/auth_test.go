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
// them must refuse without a valid credential, so the auth tests below
// run this exact list rather than a sample of it.
var nightscoutEndpoints = []string{
	"/api/v1/entries/sgv.json",
	"/api/v1/entries.json",
	"/api/v1/entries/current.json",
	"/api/v1/status.json",
	"/api/v1/experiments/test",
	"/api/v1/treatments.json",
	"/api/v1/devicestatus.json",
	"/api/v1/profile",
}

// TestEveryEndpointRequiresAuth checks, across every registered endpoint,
// that no credential and a wrong credential in either accepted form both
// get 401, and that the token query parameter and the api-secret header
// each independently let a request through when correct.
func TestEveryEndpointRequiresAuth(t *testing.T) {
	t.Parallel()
	for _, path := range nightscoutEndpoints {
		t.Run(path, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}

			cases := []struct {
				name       string
				configure  func(r *http.Request)
				wantStatus int
			}{
				{"no credential", func(r *http.Request) {}, http.StatusUnauthorized},
				{"wrong token query param", func(r *http.Request) {
					q := r.URL.Query()
					q.Set("token", "wrong-token")
					r.URL.RawQuery = q.Encode()
				}, http.StatusUnauthorized},
				{"wrong api-secret header (wrong hash)", func(r *http.Request) {
					r.Header.Set("api-secret", wrongTokenSHA1Hex)
				}, http.StatusUnauthorized},
				{"wrong api-secret header (wrong raw token)", func(r *http.Request) {
					r.Header.Set("api-secret", "wrong-token")
				}, http.StatusUnauthorized},
				{"empty token query param", func(r *http.Request) {
					q := r.URL.Query()
					q.Set("token", "")
					r.URL.RawQuery = q.Encode()
				}, http.StatusUnauthorized},
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
