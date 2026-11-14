package nightscout_test

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
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
	"/api/v2/properties/iob,cob",
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
// each independently let a request through when correct. A credential that
// is presented and wrong gets 401 on status.json too; only a request
// with no credential at all is let through there.
func TestEveryEndpointRequiresAuth(t *testing.T) {
	t.Parallel()
	for _, path := range nightscoutEndpoints {
		t.Run(path, func(t *testing.T) {
			refused := http.StatusUnauthorized
			if openEndpoints[path] {
				refused = http.StatusOK
			}
			// A presented-and-wrong credential is refused on status.json,
			// but the plain page at "/" stays open: no other route's auth changes.
			wrong := refused
			if path == "/api/v1/status.json" {
				wrong = http.StatusUnauthorized
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
				}, wrong},
				{"wrong api-secret header (wrong hash)", func(r *http.Request) {
					r.Header.Set("api-secret", wrongTokenSHA1Hex)
				}, wrong},
				{"wrong api-secret header (wrong raw token)", func(r *http.Request) {
					r.Header.Set("api-secret", "wrong-token")
				}, wrong},
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
				}, wrong},
				{"token with whitespace inside", func(r *http.Request) {
					r.URL.RawQuery = "token=correct%20-token"
				}, wrong},
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
				}, wrong},
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

// propertiesRequest serves GET path (with the credential forms in query and
// header) through a fresh handler.
func propertiesRequest(t *testing.T, path string, header map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	h, err := nightscout.New(&fakeStore{}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, path, nil)
	for k, v := range header {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// TestV2PropertiesAnswers checks the Nightscout v15.0.9 shape of
// /api/v2/properties: each requested known property is an empty object,
// unknown ones are dropped, duplicates collapse, and no number or extra key
// appears.
func TestV2PropertiesAnswers(t *testing.T) {
	t.Parallel()
	cases := []struct {
		path string
		want map[string]any
	}{
		{"/api/v2/properties/iob,cob", map[string]any{"iob": map[string]any{}, "cob": map[string]any{}}},
		{"/api/v2/properties", map[string]any{"iob": map[string]any{}, "cob": map[string]any{}}},
		{"/api/v2/properties/", map[string]any{"iob": map[string]any{}, "cob": map[string]any{}}},
		{"/api/v2/properties/cob", map[string]any{"cob": map[string]any{}}},
		{"/api/v2/properties/notaproperty", map[string]any{}},
		{"/api/v2/properties/iob,iob", map[string]any{"iob": map[string]any{}}},
		{"/api/v2/properties/iob,notaproperty", map[string]any{"iob": map[string]any{}}},
	}
	for _, c := range cases {
		t.Run(c.path, func(t *testing.T) {
			rec := propertiesRequest(t, c.path+"?token="+testToken, nil)
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
			}
			if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
				t.Errorf("Content-Type = %q, want application/json prefix", ct)
			}
			if !strings.Contains(rec.Header().Get("Vary"), "Accept-Encoding") {
				t.Errorf("Vary = %q, want it to include Accept-Encoding", rec.Header().Get("Vary"))
			}
			var got map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("body is not a JSON object: %v (%s)", err, rec.Body.String())
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("body = %v, want %v", got, c.want)
			}
		})
	}
}

// TestV2PropertiesCredentials checks that both credential forms
// open the v2 route.
func TestV2PropertiesCredentials(t *testing.T) {
	t.Parallel()
	const path = "/api/v2/properties/iob,cob"
	if rec := propertiesRequest(t, path+"?token="+testToken, nil); rec.Code != http.StatusOK {
		t.Errorf("token query: status = %d, want 200", rec.Code)
	}
	if rec := propertiesRequest(t, path, map[string]string{"api-secret": sha1Hex(testToken)}); rec.Code != http.StatusOK {
		t.Errorf("api-secret SHA-1 hex: status = %d, want 200", rec.Code)
	}
}

// TestAuthFailureUsesNightscoutBody checks every credential failure answers
// 401 with Nightscout's JSON body, on the v2 route and on v1 routes alike.
func TestAuthFailureUsesNightscoutBody(t *testing.T) {
	t.Parallel()
	want := map[string]any{"status": float64(401), "message": "Unauthorized", "description": "Invalid/Missing"}
	paths := []string{"/api/v2/properties/iob,cob", "/api/v1/entries.json"}
	for _, p := range nightscoutEndpoints {
		if !openEndpoints[p] {
			paths = append(paths, p)
		}
	}
	creds := []struct {
		name   string
		suffix string
		header map[string]string
	}{
		{"missing", "", nil},
		{"wrong token", "?token=wrong-token", nil},
		{"wrong api-secret", "", map[string]string{"api-secret": wrongTokenSHA1Hex}},
	}
	for _, p := range paths {
		for _, c := range creds {
			t.Run(p+" "+c.name, func(t *testing.T) {
				rec := propertiesRequest(t, p+c.suffix, c.header)
				if rec.Code != http.StatusUnauthorized {
					t.Fatalf("status = %d, want 401 (body: %s)", rec.Code, rec.Body.String())
				}
				if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
					t.Errorf("Content-Type = %q, want application/json prefix", ct)
				}
				var got map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
					t.Fatalf("body is not JSON: %v (%q)", err, rec.Body.String())
				}
				if !reflect.DeepEqual(got, want) {
					t.Errorf("body = %v, want %v", got, want)
				}
			})
		}
	}
}

// statusPaths are the status routes the relay serves. The relay registers
// no alias beyond status.json; a new alias belongs here so it is held to
// the same answers.
var statusPaths = []string{"/api/v1/status.json"}

// wrongStatusCredentials are the three ways a follower app presents a
// credential that is wrong: the form LoopFollow sends (token query),
// Nightguard and xDrip's api-secret header, and a Bearer header.
var wrongStatusCredentials = []struct {
	name   string
	query  string
	header map[string]string
}{
	{"wrong token query", "?token=wrong-token", nil},
	{"wrong api-secret raw", "", map[string]string{"api-secret": "wrong-token"}},
	{"wrong api-secret sha1", "", map[string]string{"api-secret": wrongTokenSHA1Hex}},
	{"wrong bearer", "", map[string]string{"Authorization": "Bearer wrong-token"}},
}

// rightStatusCredentials are the accepted forms of the right credential.
var rightStatusCredentials = []struct {
	name   string
	query  string
	header map[string]string
}{
	{"no credential", "", nil},
	{"token query", "?token=" + testToken, nil},
	{"api-secret raw token", "", map[string]string{"api-secret": testToken}},
	{"api-secret sha1", "", map[string]string{"api-secret": sha1Hex(testToken)}},
	{"bearer", "", map[string]string{"Authorization": "Bearer " + testToken}},
}

// TestStatusRejectsWrongCredential checks that every status path,
// asked with a credential that is presented and wrong in each form, answers
// 401 with Nightscout's exact JSON body, so LoopFollow's connection check
// reports Invalid Token rather than connected.
func TestStatusRejectsWrongCredential(t *testing.T) {
	t.Parallel()
	const wantBody = `{"status":401,"message":"Unauthorized","description":"Invalid/Missing"}`
	for _, p := range statusPaths {
		for _, c := range wrongStatusCredentials {
			t.Run(p+" "+c.name, func(t *testing.T) {
				rec := propertiesRequest(t, p+c.query, c.header)
				if rec.Code != http.StatusUnauthorized {
					t.Fatalf("status = %d, want 401 (body: %s)", rec.Code, rec.Body.String())
				}
				if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
					t.Errorf("Content-Type = %q, want application/json prefix", ct)
				}
				if got := strings.TrimSpace(rec.Body.String()); got != wantBody {
					t.Errorf("body = %s, want %s", got, wantBody)
				}
			})
		}
	}
}

// TestStatusAnswersNoCredentialAndRightCredential checks that
// every status path answers 200 with the status body when asked with no
// credential and with the right credential in each accepted form.
func TestStatusAnswersNoCredentialAndRightCredential(t *testing.T) {
	t.Parallel()
	for _, p := range statusPaths {
		for _, c := range rightStatusCredentials {
			t.Run(p+" "+c.name, func(t *testing.T) {
				rec := propertiesRequest(t, p+c.query, c.header)
				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
				}
				var got struct {
					Status string `json:"status"`
				}
				if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || got.Status != "ok" {
					t.Errorf("body = %q, want the status body with status ok (err %v)", rec.Body.String(), err)
				}
			})
		}
	}
}

// TestStatusWithSeveralCredentials checks that a status request presenting
// more than one credential is answered when any one of them is right and
// refused only when every one is wrong, so a follower app that sends a stale
// header beside a good token query still connects.
func TestStatusWithSeveralCredentials(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		query  string
		header map[string]string
		want   int
	}{
		{"right token query, wrong api-secret", "?token=" + testToken, map[string]string{"api-secret": "wrong-token"}, http.StatusOK},
		{"wrong token query, wrong api-secret", "?token=wrong-token", map[string]string{"api-secret": wrongTokenSHA1Hex}, http.StatusUnauthorized},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := propertiesRequest(t, "/api/v1/status.json"+c.query, c.header)
			if rec.Code != c.want {
				t.Errorf("status = %d, want %d (body: %s)", rec.Code, c.want, rec.Body.String())
			}
		})
	}
}

// TestAuthorizationSubjectsStaysUnanswered checks that
// api/v2/authorization/subjects answers 404 with a wrong token and with
// none, so LoopFollow, which asks it only after a 401, is never offered to
// create a token.
func TestAuthorizationSubjectsStaysUnanswered(t *testing.T) {
	t.Parallel()
	for _, q := range []string{"", "?token=wrong-token"} {
		rec := propertiesRequest(t, "/api/v2/authorization/subjects"+q, nil)
		if rec.Code != http.StatusNotFound {
			t.Errorf("subjects%s: status = %d, want 404 (body: %s)", q, rec.Code, rec.Body.String())
		}
	}
}
