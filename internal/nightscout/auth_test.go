package nightscout_test

import (
	"bufio"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
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

// sentinelMgDl is a glucose value no other fixture uses, so finding it in a
// body proves the route served stored data rather than only answering 200.
const sentinelMgDl = 237

// rawRequest parses raw (CRLF lines, as a client writes them) with Go's own
// request reader, so a repeated header arrives as several lines exactly as
// it does on the wire, then answers it through the real handler.
func rawRequest(t *testing.T, raw string) *httptest.ResponseRecorder {
	t.Helper()
	h, err := nightscout.New(&fakeStore{readings: []cgm.Reading{reading(time.Now(), sentinelMgDl)}}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	req, err := http.ReadRequest(bufio.NewReader(strings.NewReader(raw)))
	if err != nil {
		t.Fatalf("ReadRequest: %v", err)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// getRaw builds the raw text of a GET for target carrying each header line
// in order, repeats included.
func getRaw(target string, headerLines ...string) string {
	return "GET " + target + " HTTP/1.1\r\nHost: relay.test\r\n" + strings.Join(append(headerLines, ""), "\r\n") + "\r\n"
}

// TestRepeatedCredentialsAnyValidWins checks that a credential sent more
// than once is judged by every occurrence: a right one wins wherever it
// sits, a blank one is no credential, and a request whose only non-blank
// values are wrong is refused. Reading only the first occurrence lets a
// blank value hide a wrong one (a wrong token answered as if none was
// sent) and a wrong or blank one hide a right one (a follower app whose
// settings add a stale value ahead of the real one is locked out).
func TestRepeatedCredentialsAnyValidWins(t *testing.T) {
	t.Parallel()
	const status = "/api/v1/status.json"
	secretSHA1 := sha1Hex(testToken)
	const (
		refused = http.StatusUnauthorized
		served  = http.StatusOK
	)
	cases := []struct {
		name   string
		target string
		header []string
		want   int
	}{
		{"blank then wrong token query", status + "?token=&token=wrong", nil, refused},
		{"whitespace then wrong token query", status + "?token=%20&token=wrong", nil, refused},
		{"blank then wrong api-secret", status, []string{"Api-Secret: ", "Api-Secret: wrong"}, refused},
		{"blank then wrong bearer", status, []string{"Authorization: ", "Authorization: Bearer wrong"}, refused},
		{"wrong then wrong token query", status + "?token=wrong&token=other", nil, refused},
		{"wrong then right token query", status + "?token=wrong&token=" + testToken, nil, served},
		{"blank then right token query", status + "?token=&token=" + testToken, nil, served},
		{"wrong then right api-secret raw", status, []string{"Api-Secret: wrong", "Api-Secret: " + testToken}, served},
		{"wrong then right api-secret sha1", status, []string{"Api-Secret: wrong", "Api-Secret: " + secretSHA1}, served},
		{"wrong then right bearer", status, []string{"Authorization: Bearer wrong", "Authorization: Bearer " + testToken}, served},
		{"right then wrong token query", status + "?token=" + testToken + "&token=wrong", nil, served},
		{"right then wrong api-secret", status, []string{"Api-Secret: " + testToken, "Api-Secret: wrong"}, served},
		{"right then wrong bearer", status, []string{"Authorization: Bearer " + testToken, "Authorization: Bearer wrong"}, served},
		{"blank token query twice", status + "?token=&token=", nil, served},
		{"whitespace token query twice", status + "?token=%20&token=%09", nil, served},
		{"blank api-secret twice", status, []string{"Api-Secret: ", "Api-Secret:  "}, served},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := rawRequest(t, getRaw(c.target, c.header...))
			if rec.Code != c.want {
				t.Fatalf("status = %d, want %d (body: %s)", rec.Code, c.want, rec.Body.String())
			}
			if c.want == refused {
				if got := rec.Body.String(); got != `{"status":401,"message":"Unauthorized","description":"Invalid/Missing"}`+"\n" {
					t.Errorf("body = %q, want Nightscout's refusal", got)
				}
			} else if !strings.Contains(rec.Body.String(), `"status":"ok"`) {
				t.Errorf("body = %s, want the ordinary status object", rec.Body.String())
			}
		})
	}
}

// TestRepeatedCredentialsOnProtectedRoutes checks every route that needs a
// credential: a right token query or api-secret still lets the request in
// when a blank or wrong one of the same kind comes first, a request whose
// only non-blank values are wrong is refused, and a lone Bearer header
// stays no credential there. A reading with a value no other test uses is
// stored so a data route answering 200 has to have served it.
func TestRepeatedCredentialsOnProtectedRoutes(t *testing.T) {
	t.Parallel()
	routes := []string{"/api/v2/properties"}
	for _, p := range nightscoutEndpoints {
		if !openEndpoints[p] {
			routes = append(routes, p)
		}
	}
	servesReadings := map[string]bool{
		"/api/v1/entries/sgv.json":     true,
		"/api/v1/entries.json":         true,
		"/api/v1/entries/current.json": true,
	}
	type variant struct {
		name   string
		query  []string
		header []string
		ok     bool
	}
	variants := []variant{
		{"blank then right token query", []string{"token=", "token=" + testToken}, nil, true},
		{"wrong then right token query", []string{"token=wrong", "token=" + testToken}, nil, true},
		{"blank then right api-secret", nil, []string{"Api-Secret: ", "Api-Secret: " + testToken}, true},
		{"wrong then right api-secret raw", nil, []string{"Api-Secret: wrong", "Api-Secret: " + testToken}, true},
		{"wrong then right api-secret sha1", nil, []string{"Api-Secret: wrong", "Api-Secret: " + sha1Hex(testToken)}, true},
		{"wrong then wrong token query", []string{"token=wrong", "token=other"}, nil, false},
		{"blank then wrong token query", []string{"token=", "token=wrong"}, nil, false},
		{"wrong then wrong api-secret", nil, []string{"Api-Secret: wrong", "Api-Secret: other"}, false},
		{"blank then wrong api-secret", nil, []string{"Api-Secret: ", "Api-Secret: wrong"}, false},
		{"bearer alone", nil, []string{"Authorization: Bearer " + testToken}, false},
		{"wrong then right bearer", nil, []string{"Authorization: Bearer wrong", "Authorization: Bearer " + testToken}, false},
	}
	for _, route := range routes {
		for _, v := range variants {
			t.Run(route+" "+v.name, func(t *testing.T) {
				target := route
				if len(v.query) > 0 {
					target += "?" + strings.Join(v.query, "&")
				}
				rec := rawRequest(t, getRaw(target, v.header...))
				if !v.ok {
					if rec.Code != http.StatusUnauthorized {
						t.Fatalf("status = %d, want 401 (body: %s)", rec.Code, rec.Body.String())
					}
					return
				}
				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
				}
				if servesReadings[route] && !strings.Contains(rec.Body.String(), "237") {
					t.Errorf("body = %s, want the stored reading %d", rec.Body.String(), sentinelMgDl)
				}
			})
		}
	}
}
