package pairing_test

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/pairing"
)

const testToken = "tok_ABC-123_defGHI456jklMNO789pqrSTU0vwx-yz"

type fakeClock struct{ now time.Time }

func (c *fakeClock) Now() time.Time { return c.now }

func newTestStore() (*pairing.Store, *fakeClock) {
	clk := &fakeClock{now: time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)}
	return pairing.NewStore(clk.Now), clk
}

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

// sampleApps is what the Mac app sends: its wording and its values, with
// the token left as a placeholder.
func sampleApps() []pairing.App {
	return []pairing.App{
		{
			Name:  "First App",
			Steps: []string{"Open Settings <b>now</b>.", "Leave the secret blank."},
			Fields: []pairing.Field{
				{Label: "URL", Value: "https://relay.example.net"},
				{Label: "Token", Value: "{token}"},
			},
			Links: []pairing.Link{{Label: "Open First App", URL: "xdripswift://open"}},
		},
		{
			Name:   "Second App",
			Steps:  []string{"Paste the address."},
			Fields: []pairing.Field{{Label: "Follow URL", Value: "https://{token}@relay.example.net:8443"}},
			Links:  []pairing.Link{{Label: "Get Second App", URL: "https://apps.example.com/second"}},
		},
	}
}

func mustMint(t *testing.T, s *pairing.Store) string {
	t.Helper()
	code, _, err := s.Mint(sampleApps())
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	return code
}

func TestLiveCodeServesPageWithTokenAndEveryHeader(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	code := mustMint(t, store)
	rec := get(pairing.PageHandler(store, testToken), "/connect/"+code)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, testToken) {
		t.Error("page does not show the token")
	}
	for name, want := range map[string]string{
		"Cache-Control":   "no-store",
		"Referrer-Policy": "no-referrer",
		"X-Robots-Tag":    "noindex",
	} {
		if got := rec.Header().Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if csp := rec.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") {
		t.Errorf("Content-Security-Policy = %q, want default-src 'none'", csp)
	}
	if !strings.Contains(body, `href="xdripswift://open"`) {
		t.Error("page has no Open xDrip4iOS link")
	}
}

func TestPageShowsExactlyTheMintedAppsAndInsertsTheTokenWhereAskedOnly(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	code := mustMint(t, store)
	body := get(pairing.PageHandler(store, testToken), "/connect/"+code).Body.String()

	for _, want := range []string{
		">First App</h2>", ">Second App</h2>",
		">https://relay.example.net</code>",
		">" + testToken + "</code>",
		">https://" + testToken + "@relay.example.net:8443</code>",
		"Leave the secret blank.",
		`href="xdripswift://open"`, `href="https://apps.example.com/second"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("page lacks %q", want)
		}
	}
	if strings.Contains(body, "{token}") {
		t.Error("a token placeholder was left unfilled")
	}
	if strings.Contains(body, "<b>now</b>") || !strings.Contains(body, "&lt;b&gt;now&lt;/b&gt;") {
		t.Error("app wording was not HTML-escaped")
	}
}

func TestUnknownAndExpiredCodesServeNoToken(t *testing.T) {
	t.Parallel()
	store, clk := newTestStore()
	code := mustMint(t, store)
	h := pairing.PageHandler(store, testToken)

	clk.now = clk.now.Add(pairing.CodeLifetime)
	cases := map[string]string{
		"expired":       "/connect/" + code,
		"unknown":       "/connect/AAAAAAAAAAAAAAAAAAAAAA",
		"empty":         "/connect/",
		"wrong length":  "/connect/" + code[:5],
		"code and more": "/connect/" + code + "x",
	}
	for name, path := range cases {
		t.Run(name, func(t *testing.T) {
			rec := get(h, path)
			if rec.Code != http.StatusGone {
				t.Errorf("status = %d, want 410", rec.Code)
			}
			if strings.Contains(rec.Body.String(), testToken) || strings.Contains(rec.Header().Get("Content-Security-Policy"), testToken) {
				t.Error("response carries the token")
			}
			if !strings.Contains(rec.Body.String(), "expired") {
				t.Error("page does not say the code expired")
			}
			if rec.Header().Get("Cache-Control") != "no-store" {
				t.Error("missing Cache-Control: no-store")
			}
		})
	}
}

func TestCodeIsLiveUntilItsLifetimeEnds(t *testing.T) {
	t.Parallel()
	store, clk := newTestStore()
	code := mustMint(t, store)
	clk.now = clk.now.Add(pairing.CodeLifetime - time.Second)
	if _, ok := store.Lookup(code); !ok {
		t.Error("code expired early")
	}
	clk.now = clk.now.Add(time.Second)
	if _, ok := store.Lookup(code); ok {
		t.Error("code still live at its expiry")
	}
}

func TestMintingReplacesTheOutstandingCode(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	first := mustMint(t, store)
	second := mustMint(t, store)
	if first == second {
		t.Fatal("two mints returned the same code")
	}
	if _, ok := store.Lookup(first); ok {
		t.Error("the replaced code still works")
	}
	if _, ok := store.Lookup(second); !ok {
		t.Error("the new code does not work")
	}
	if rec := get(pairing.PageHandler(store, testToken), "/connect/"+first); rec.Code != http.StatusGone || strings.Contains(rec.Body.String(), testToken) {
		t.Errorf("replaced code: status %d, token leaked = %v", rec.Code, strings.Contains(rec.Body.String(), testToken))
	}
}

func TestCodeCarriesAtLeast128BitsAsBase64URL(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	code := mustMint(t, store)
	raw, err := base64.RawURLEncoding.DecodeString(code)
	if err != nil {
		t.Fatalf("code is not unpadded base64url: %v", err)
	}
	if len(raw) < 16 {
		t.Errorf("code decodes to %d bytes, want at least 16", len(raw))
	}
}

func TestMintRejectsMalformedApps(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	ok := sampleApps()
	mutate := func(f func(a []pairing.App) []pairing.App) []pairing.App { return f(sampleApps()) }
	cases := map[string][]pairing.App{
		"none": nil,
		"too many": mutate(func(a []pairing.App) []pairing.App {
			for len(a) < 9 {
				a = append(a, a[0])
			}
			return a
		}),
		"unnamed":           mutate(func(a []pairing.App) []pairing.App { a[0].Name = ""; return a }),
		"empty step":        mutate(func(a []pairing.App) []pairing.App { a[0].Steps = []string{""}; return a }),
		"empty field value": mutate(func(a []pairing.App) []pairing.App { a[0].Fields[0].Value = ""; return a }),
		"script link":       mutate(func(a []pairing.App) []pairing.App { a[0].Links[0].URL = "javascript:alert(1)"; return a }),
		"plain http link":   mutate(func(a []pairing.App) []pairing.App { a[0].Links[0].URL = "http://example.com"; return a }),
		"very long step":    mutate(func(a []pairing.App) []pairing.App { a[0].Steps = []string{strings.Repeat("x", 600)}; return a }),
	}
	for name, apps := range cases {
		if _, _, err := store.Mint(apps); err == nil {
			t.Errorf("%s: Mint succeeded, want an error", name)
		}
	}
	if _, _, err := store.Mint(ok); err != nil {
		t.Errorf("a well-formed request was refused: %v", err)
	}
}

func TestPageIsSelfContainedAndItsCSPNamesItsInlineResources(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	code := mustMint(t, store)
	rec := get(pairing.PageHandler(store, testToken), "/connect/"+code)
	body := rec.Body.String()
	csp := rec.Header().Get("Content-Security-Policy")

	for _, m := range []struct{ tag, directive string }{{"style", "style-src"}, {"script", "script-src"}} {
		re := regexp.MustCompile(`(?s)<` + m.tag + `>(.*?)</` + m.tag + `>`)
		found := re.FindAllStringSubmatch(body, -1)
		if len(found) != 1 {
			t.Fatalf("page has %d <%s> blocks, want exactly 1", len(found), m.tag)
		}
		sum := sha256.Sum256([]byte(found[0][1]))
		hash := "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
		if !strings.Contains(csp, m.directive+" "+hash) {
			t.Errorf("CSP %q does not name the page's %s by hash %s", csp, m.tag, hash)
		}
	}
	for _, banned := range []string{" src=", "<link", "@import", "url(", "<img", "<iframe", "onclick="} {
		if strings.Contains(body, banned) {
			t.Errorf("page carries %q, an external or inline-handler resource", banned)
		}
	}
	if regexp.MustCompile(`style="`).MatchString(body) {
		t.Error("page carries an inline style attribute the CSP would block")
	}
}

func TestEveryCopyButtonHasAnAccessibleNameAndItsValue(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	code := mustMint(t, store)
	body := get(pairing.PageHandler(store, testToken), "/connect/"+code).Body.String()

	buttons := regexp.MustCompile(`<button[^>]*class="btn copy"[^>]*>`).FindAllString(body, -1)
	if len(buttons) != 3 {
		t.Fatalf("found %d Copy buttons, want 3: one per minted field", len(buttons))
	}
	for _, b := range buttons {
		id := regexp.MustCompile(`data-for="([^"]+)"`).FindStringSubmatch(b)
		if id == nil || !strings.Contains(body, `id="`+id[1]+`"`) {
			t.Errorf("button %s names no value on the page", b)
		}
		if !strings.Contains(b, `aria-label="Copy `) {
			t.Errorf("button %s has no spoken label", b)
		}
	}
}

func TestPageHandlerOnlyAnswersGET(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	code := mustMint(t, store)
	rec := httptest.NewRecorder()
	pairing.PageHandler(store, testToken).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/connect/"+code, nil))
	if rec.Code != http.StatusMethodNotAllowed || strings.Contains(rec.Body.String(), testToken) {
		t.Errorf("POST: status %d, want 405 with no token", rec.Code)
	}
}

const mintBody = `{"apps":[{"name":"A","steps":["s"],"fields":[{"label":"URL","value":"https://h"}],"links":[]}]}`

func mintRequest(t *testing.T, h http.Handler, remote, contentType, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/pairing", strings.NewReader(body))
	req.RemoteAddr = remote
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestMintRouteMintsForALocalCaller(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	rec := mintRequest(t, pairing.MintHandler(store), "127.0.0.1:50000", "application/json", mintBody)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Code      string    `json:"code"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if apps, ok := store.Lookup(resp.Code); !ok || len(apps) != 1 {
		t.Errorf("minted code does not resolve: %d apps, %v", len(apps), ok)
	}
	if !resp.ExpiresAt.Equal(time.Date(2026, 6, 1, 12, 10, 0, 0, time.UTC)) {
		t.Errorf("expires_at = %v, want ten minutes on", resp.ExpiresAt)
	}
}

func TestMintRouteRefusesAnyNonLocalCallerAndMintsNothing(t *testing.T) {
	t.Parallel()
	body := mintBody
	for _, remote := range []string{"100.101.102.5:50000", "192.168.1.9:50000", "[2001:db8::1]:50000", "not-an-address", ""} {
		t.Run(remote, func(t *testing.T) {
			store, _ := newTestStore()
			existing := mustMint(t, store)
			rec := mintRequest(t, pairing.MintHandler(store), remote, "application/json", body)
			if rec.Code != http.StatusForbidden {
				t.Errorf("status = %d, want 403", rec.Code)
			}
			if _, ok := store.Lookup(existing); !ok {
				t.Error("a refused caller replaced the outstanding code")
			}
		})
	}
}

func TestMintRouteRefusesBodiesAWebPageCouldSend(t *testing.T) {
	t.Parallel()
	store, _ := newTestStore()
	h := pairing.MintHandler(store)
	body := mintBody
	for name, ct := range map[string]string{"none": "", "text/plain": "text/plain", "form": "application/x-www-form-urlencoded"} {
		if rec := mintRequest(t, h, "127.0.0.1:1", ct, body); rec.Code != http.StatusUnsupportedMediaType {
			t.Errorf("content type %s: status = %d, want 415", name, rec.Code)
		}
	}
	for name, b := range map[string]string{
		"empty":                    "",
		"unknown field":            `{"apps":[],"extra":1}`,
		"no apps":                  `{"apps":[]}`,
		"object then second value": mintBody + `{"apps":[]}`,
		"object then junk":         mintBody + ` x`,
		"object then two objects":  mintBody + "\n" + mintBody,
	} {
		if rec := mintRequest(t, h, "127.0.0.1:1", "application/json", b); rec.Code != http.StatusBadRequest {
			t.Errorf("body %s: status = %d, want 400", name, rec.Code)
		}
	}
	for name, b := range map[string]string{
		"object then over-limit whitespace": mintBody + strings.Repeat(" ", 33<<10),
		"over-limit body":                   `{"apps":[{"name":"` + strings.Repeat("a", 33<<10) + `","steps":[],"fields":[],"links":[]}]}`,
	} {
		if rec := mintRequest(t, h, "127.0.0.1:1", "application/json", b); rec.Code != http.StatusRequestEntityTooLarge {
			t.Errorf("body %s: status = %d, want 413", name, rec.Code)
		}
	}
	if rec := mintRequest(t, h, "127.0.0.1:1", "application/json", mintBody+"\n \t\n"); rec.Code != http.StatusOK {
		t.Errorf("one object followed by whitespace: status = %d, want 200", rec.Code)
	}
}
