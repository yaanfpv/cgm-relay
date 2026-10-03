package nightscout_test

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/nightscout"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// A real *store.Store must keep satisfying nightscout.ReadingRange, since
// that is the whole reason the interface exists: to let this package be
// wired to the real store without either package depending on the other's
// concrete type beyond this one method.
var _ nightscout.ReadingRange = (*store.Store)(nil)

// TestNewRejectsEmptyToken checks that a handler cannot be built without
// a token, because a handler with no token would serve readings to anyone
// who could reach it.
func TestNewRejectsEmptyToken(t *testing.T) {
	t.Parallel()
	h, err := nightscout.New(&fakeStore{}, "", nil)
	if err == nil {
		t.Fatal("New with an empty token returned no error, want one")
	}
	if h != nil {
		t.Error("New with an empty token returned a non-nil handler, want nil")
	}
}

// TestNewRejectsNilReadings checks that New refuses a nil ReadingRange
// rather than building a handler that would panic on its first request.
func TestNewRejectsNilReadings(t *testing.T) {
	t.Parallel()
	h, err := nightscout.New(nil, "s3cr3t", nil)
	if err == nil {
		t.Fatal("New with a nil ReadingRange returned no error, want one")
	}
	if h != nil {
		t.Error("New with a nil ReadingRange returned a non-nil handler, want nil")
	}
}

// TestNewAcceptsNilClock checks that a nil clock is tolerated (New falls
// back to time.Now) rather than the handler panicking on its first call to
// an endpoint that reports the time.
func TestNewAcceptsNilClock(t *testing.T) {
	t.Parallel()
	if _, err := nightscout.New(&fakeStore{}, "s3cr3t", nil); err != nil {
		t.Fatalf("New with a nil clock: %v", err)
	}
}

// fixedClock returns a nightscout.Clock that always reports t, for tests
// that assert on a status response's reported server time.
func fixedClock(t time.Time) nightscout.Clock {
	return func() time.Time { return t }
}

// TestUnimplementedPathReturns404BeforeAuth checks that a path this handler
// does not register answers 404 even with no credential at all, never 401.
// Nightguard's own capability probe (NightscoutService.determineV3Support,
// GET /api/v3/version with no credential) treats any response other than
// 404 or 405 as a fatal error rather than falling back to the v1 API this
// handler implements, so an unimplemented path must never reach checkAuth.
func TestUnimplementedPathReturns404BeforeAuth(t *testing.T) {
	t.Parallel()
	h, err := nightscout.New(&fakeStore{}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	for _, path := range []string{"/api/v3/version", "/api/v1/nonexistent.json"} {
		t.Run(path, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, path, nil)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusNotFound {
				t.Errorf("status = %d, want %d (body: %s)", rec.Code, http.StatusNotFound, rec.Body.String())
			}
		})
	}
}

// TestRootPage checks the plain page at "/", which follower apps open when
// someone taps a service status: it answers 200 with no credential, names
// the relay, carries the hardening headers, and shows no reading, token,
// account, address or version; while any other unregistered path, and any
// method but GET, still gets no page.
func TestRootPage(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	h, err := nightscout.New(&fakeStore{readings: []cgm.Reading{reading(now, 123)}}, testToken, fixedClock(now))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "<title>CGM Relay</title>") || !strings.Contains(body, "access token") {
		t.Errorf("page lacks its title or its explanation: %s", body)
	}
	for _, leak := range []string{testToken, "123", "mg/dl", "http", "version"} {
		if strings.Contains(body, leak) {
			t.Errorf("page contains %q: %s", leak, body)
		}
	}
	if got := rec.Header().Get("Content-Type"); !strings.HasPrefix(got, "text/html") {
		t.Errorf("Content-Type = %q, want text/html", got)
	}
	for header, want := range map[string]string{
		"X-Content-Type-Options":  "nosniff",
		"X-Robots-Tag":            "noindex",
		"Referrer-Policy":         "no-referrer",
		"Content-Security-Policy": "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
	} {
		if got := rec.Header().Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}

	for _, c := range []struct{ method, path string }{
		{http.MethodGet, "/index.html"},
		{http.MethodGet, "/api"},
		{http.MethodGet, "/api/v1/"},
		{http.MethodPost, "/"},
	} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(c.method, c.path, nil))
		if rec.Code == http.StatusOK {
			t.Errorf("%s %s answered 200, want no page", c.method, c.path)
		}
	}
}

// credentialForm names how a follower app attaches its credential to a
// request, so a followerRequest row can be built, and its no-credential and
// wrong-credential counterparts derived, without repeating that logic once
// per row.
type credentialForm int

const (
	// credentialNone is Nightguard's own /api/v3/version probe: it sends
	// no credential of any kind, by design (see followerRequests' N1).
	credentialNone credentialForm = iota
	// credentialTokenQuery is the raw token as a "token" query parameter.
	credentialTokenQuery
	// credentialAPISecretSHA1 is an "api-secret" header holding the
	// hex-encoded SHA-1 of the token (xDrip4iOS, xDrip+).
	credentialAPISecretSHA1
	// credentialAPISecretRaw is an "api-secret" header holding the raw
	// token itself (Nightguard's legacy v1 requests).
	credentialAPISecretRaw
)

// applyCredential attaches secret to r in form. Called with the right
// token it reproduces the row's real credential; called with a wrong
// value it reproduces a well-formed but incorrect one of the same shape
// (a wrong hash for the SHA-1 form, a wrong raw string for the other two),
// never a malformed header that would fail for an unrelated reason.
func applyCredential(r *http.Request, form credentialForm, secret string) {
	switch form {
	case credentialTokenQuery:
		q := r.URL.Query()
		q.Set("token", secret)
		r.URL.RawQuery = q.Encode()
	case credentialAPISecretSHA1:
		r.Header.Set("api-secret", sha1Hex(secret))
	case credentialAPISecretRaw:
		r.Header.Set("api-secret", secret)
	}
}

// followerRequest is one real request a follower app sends while
// following a Nightscout site, cited from that app's own source so this
// row can be checked against it without re-deriving anything.
type followerRequest struct {
	// name identifies the app, a short row id, and the exact source
	// citation (repo@branch, file, lines) it was read from.
	name       string
	method     string
	path       string
	query      url.Values
	credential credentialForm
	// wantStatus is this handler's answer to the row's request when it
	// carries the right credential (or always, for a credentialNone row).
	wantStatus int
	// note records, for a wantStatus 404 row, why that app's own failure
	// handling makes the unimplemented path harmless to following (or, for
	// N1, why 404 is the outcome the app's own logic actually requires).
	note string
}

// request builds the row's request, applying secret in the row's own
// credential form. secret == "" and credential == credentialNone both
// send no credential at all; passing a non-empty secret to a
// credentialNone row (N1) still attaches nothing, matching Nightguard's
// real unauthenticated probe exactly.
func (row followerRequest) request(secret string) *http.Request {
	req := httptest.NewRequest(row.method, row.path, nil)
	if row.query != nil {
		req.URL.RawQuery = row.query.Encode()
	}
	if row.credential != credentialNone && secret != "" {
		applyCredential(req, row.credential, secret)
	}
	return req
}

// followerRequests is the compatibility contract itself: every request
// the four follower apps named in the package documentation are
// confirmed, from their own source, to send while following a Nightscout
// site. TestFollowerAppRequests runs each row against this handler and is
// the test that goes red the moment a future change stops answering one
// of them the way this table says it must.
var followerRequests = []followerRequest{
	{
		name:       "Nightguard N1: github.com/nightscout/nightguard@master NightscoutService.swift determineV3Support ~190-247, request() ~597-608 (no auth header at all)",
		method:     http.MethodGet,
		path:       "/api/v3/version",
		credential: credentialNone,
		wantStatus: http.StatusNotFound,
		note:       "required, not merely tolerated: Nightguard's determineV3Support treats any status other than 404/405 as fatal and never falls back to v1 (lines 232-243), so this relay must answer 404 here for Nightguard to be able to follow it at all",
	},
	{
		name:       "Nightguard N2: nightguard@master NightscoutService.swift performLegacy ~356-402 called with useAccessTokenHeader:true from readChartData line 738",
		method:     http.MethodGet,
		path:       "/api/v1/entries.json",
		query:      url.Values{"count": {"20"}},
		credential: credentialAPISecretRaw,
		wantStatus: http.StatusOK,
	},
	{
		name:       "Nightguard N3: nightguard@master NightscoutService.swift readLegacyStatus ~972-992 (requestLegacy useAccessTokenHeader:true)",
		method:     http.MethodGet,
		path:       "/api/v1/status.json",
		credential: credentialAPISecretRaw,
		wantStatus: http.StatusOK,
	},
	{
		name:       "Nightguard N4: nightguard@master NightscoutService.swift readDeviceStatus ~1966-1994 (requestLegacy useAccessTokenHeader:true)",
		method:     http.MethodGet,
		path:       "/api/v1/devicestatus.json",
		query:      url.Values{"count": {"5"}},
		credential: credentialAPISecretRaw,
		wantStatus: http.StatusOK,
	},
	{
		name:       "Nightguard N5: nightguard@master NightscoutService.swift legacyURL ~404-410 falling to UserDefaultsRepository.getUrlWithPathAndQueryParameters, which appends token=<value> (UserDefaultsRepository.swift 261-282)",
		method:     http.MethodGet,
		path:       "/api/v1/entries.json",
		query:      url.Values{"count": {"1"}},
		credential: credentialTokenQuery,
		wantStatus: http.StatusOK,
	},
	{
		name:       "Nightguard N6: nightguard@master NightscoutService.swift readLastTreatementEventTimestamp line 1789 / readLastTemporaryTarget line 1840, legacy path \"api/v1/treatments\" (no .json)",
		method:     http.MethodGet,
		path:       "/api/v1/treatments",
		query:      url.Values{"count": {"1"}},
		credential: credentialTokenQuery,
		wantStatus: http.StatusOK,
	},
	{
		name:       "Nightguard N7: nightguard@master NightscoutService.swift readLatestTreatements line 2046, legacy path \"api/v1/treatments.json\"",
		method:     http.MethodGet,
		path:       "/api/v1/treatments.json",
		query:      url.Values{"count": {"500"}},
		credential: credentialTokenQuery,
		wantStatus: http.StatusOK,
	},
	{
		name:       "xDrip4iOS X1: github.com/JohanDegraeve/xdripswift@develop Endpoint+Nightscout.swift getEndpointForLatestNSEntries 15-47, NightscoutFollowManager.swift 203-216 (api-secret = apiKey.sha1())",
		method:     http.MethodGet,
		path:       "/api/v1/entries/sgv.json",
		query:      url.Values{"count": {"10"}, "find[date][$gte]": {"0"}},
		credential: credentialAPISecretSHA1,
		wantStatus: http.StatusOK,
	},
	{
		name:       "xDrip4iOS X2: xdripswift@develop NightscoutSyncManager.swift updateProfile line 893, nightscoutProfilePath line 67 = \"/api/v1/profile\"",
		method:     http.MethodGet,
		path:       "/api/v1/profile",
		credential: credentialAPISecretSHA1,
		wantStatus: http.StatusOK,
	},
	{
		name:       "xDrip4iOS X3: xdripswift@develop NightscoutSyncManager.swift updateDeviceStatus line 951, nightscoutDeviceStatusPath line 61 = \"/api/v1/devicestatus\" (no .json)",
		method:     http.MethodGet,
		path:       "/api/v1/devicestatus",
		credential: credentialAPISecretSHA1,
		wantStatus: http.StatusOK,
	},
	{
		name:       "xDrip4iOS X4: xdripswift@develop NightscoutSyncManager.swift testNightscoutCredentials 2004-2026, nightscoutAuthTestPath = \"/api/v1/experiments/test\"",
		method:     http.MethodGet,
		path:       "/api/v1/experiments/test",
		credential: credentialAPISecretSHA1,
		wantStatus: http.StatusOK,
	},
	{
		name:       "xDrip+ P1: github.com/NightscoutFoundation/xDrip@master NightscoutFollow.java getEntries/getEntriesSince 52-56, NightscoutUrl.java getHashedSecret() (SHA-1 of the URL's userinfo secret)",
		method:     http.MethodGet,
		path:       "/api/v1/entries.json",
		query:      url.Values{"count": {"10"}, "rr": {"1000"}},
		credential: credentialAPISecretSHA1,
		wantStatus: http.StatusOK,
	},
	{
		name:       "xDrip+ P2: xDrip@master NightscoutFollow.java getTreatments 58-59, called at line 126, only when nsfollow_download_treatments is on",
		method:     http.MethodGet,
		path:       "/api/v1/treatments",
		credential: credentialAPISecretSHA1,
		wantStatus: http.StatusOK,
	},
	{
		name:       "xDrip+ P3: xDrip@master NightscoutFollow.java getDeviceStatus 61-62, gated by NsServerCapabilities.supportsDeviceStatus and self-disabled after a 4xx (133-141, 205-216)",
		method:     http.MethodGet,
		path:       "/api/v1/devicestatus.json",
		query:      url.Values{"count": {"1"}},
		credential: credentialAPISecretSHA1,
		wantStatus: http.StatusOK,
	},
	{
		name:       "LoopFollow L1: github.com/loopandlearn/LoopFollow@main NightscoutUtils.swift verifyURLAndToken 202-276 / createURLRequest 152-167",
		method:     http.MethodGet,
		path:       "/api/v1/status.json",
		credential: credentialTokenQuery,
		wantStatus: http.StatusOK,
	},
	{
		name:       "LoopFollow L2: LoopFollow@main BGData.swift webLoadNSBGData 62-78, EventType.sgv.endpoint line 55",
		method:     http.MethodGet,
		path:       "/api/v1/entries.json",
		query:      url.Values{"count": {"2016"}, "find[date][$gte]": {"0"}, "find[type][$ne]": {"cal"}},
		credential: credentialTokenQuery,
		wantStatus: http.StatusOK,
	},
	{
		name:       "LoopFollow L3: LoopFollow@main NightscoutUtils.swift EventType.profile.endpoint line 57 = \"/api/v1/profiles.json\", Profile.swift webLoadNSProfile 8-27",
		method:     http.MethodGet,
		path:       "/api/v1/profiles.json",
		credential: credentialTokenQuery,
		wantStatus: http.StatusOK,
	},
	{
		name:       "LoopFollow L4: LoopFollow@main NightscoutUtils.swift EventType.endpoint 52-53, Treatments.swift 49-51 (cage/carbsToday/sage/iage)",
		method:     http.MethodGet,
		path:       "/api/v1/treatments.json",
		query:      url.Values{"count": {"500"}, "find[created_at][$gte]": {"2026-01-01T00:00:00.000Z"}, "find[created_at][$lte]": {"2026-01-02T00:00:00.000Z"}},
		credential: credentialTokenQuery,
		wantStatus: http.StatusOK,
	},
	{
		name:       "LoopFollow L5: LoopFollow@main NightscoutUtils.swift EventType.deviceStatus.endpoint line 59, DeviceStatus.swift 10-11",
		method:     http.MethodGet,
		path:       "/api/v1/devicestatus.json",
		query:      url.Values{"count": {"1"}},
		credential: credentialTokenQuery,
		wantStatus: http.StatusOK,
	},
	{
		name:       "LoopFollow L6: LoopFollow@main NightscoutUtils.swift retrieveJWTToken 306-346 / executePostRequest 348-410, EventType.temporaryOverride(Cancel) 46-47/60-61",
		method:     http.MethodPost,
		path:       "/api/v2/notifications/loop",
		credential: credentialNone,
		wantStatus: http.StatusNotFound,
		note:       "this exact request is never issued by LoopFollow against this relay: executePostRequest always calls retrieveJWTToken first, which itself GETs /api/v1/status.json (L1's own request) looking for an \"authorized\" object this relay's status.json never carries, and throws before the POST is ever built (line 338-342) — tested with no credential at all, the strongest available claim, to confirm the write path is inert even if a future LoopFollow version reached it",
	},
	{
		name:       "LoopFollow L7: LoopFollow@main NightscoutUtils.swift EventType.dbSize.endpoint 62-63, DBSizeTask.swift (whole file) scheduling webLoadNSDBSize, DBSize.swift (whole file)",
		method:     http.MethodGet,
		path:       "/api/v2/properties/dbsize",
		credential: credentialTokenQuery,
		wantStatus: http.StatusNotFound,
		note:       "harmless: webLoadNSDBSize's .failure case only logs (DBSize.swift), which clears the db-size info pill via updateDBSize's own guard; dbSizeTaskAction reschedules itself unconditionally every 6 hours regardless of success or failure (DBSizeTask.swift), so a 404 here never blocks or delays any other periodic task",
	},
}

// aliasPairs maps each path a follower app requests an empty collection by
// to the path that answers the same collection under its other spelling.
// Each alias must answer exactly what its sibling answers.
var aliasPairs = []struct{ alias, sibling string }{
	{"/api/v1/treatments", "/api/v1/treatments.json"},
	{"/api/v1/devicestatus", "/api/v1/devicestatus.json"},
	{"/api/v1/profiles.json", "/api/v1/profile"},
}

// TestAliasesAnswerAsTheirSibling checks, for every credential form the
// relay accepts, that an alias returns the same status, content type and
// body as its sibling, and is served only with the right token.
func TestAliasesAnswerAsTheirSibling(t *testing.T) {
	t.Parallel()
	h, err := nightscout.New(&fakeStore{}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	forms := []struct {
		name string
		form credentialForm
	}{
		{"token query", credentialTokenQuery},
		{"api-secret SHA-1", credentialAPISecretSHA1},
		{"api-secret raw", credentialAPISecretRaw},
	}
	get := func(path string, form credentialForm, secret string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if secret != "" {
			applyCredential(req, form, secret)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	for _, p := range aliasPairs {
		for _, f := range forms {
			for _, secret := range []string{testToken, "", "wrong-token"} {
				t.Run(p.alias+" "+f.name+" secret="+secret, func(t *testing.T) {
					want := get(p.sibling, f.form, secret)
					got := get(p.alias, f.form, secret)
					if served := got.Code == http.StatusOK; served != (secret == testToken) {
						t.Fatalf("alias status = %d for secret %q, want it served only with the right token", got.Code, secret)
					}
					if got.Code != want.Code {
						t.Errorf("alias status = %d, sibling %s answers %d", got.Code, p.sibling, want.Code)
					}
					if gc, wc := got.Header().Get("Content-Type"), want.Header().Get("Content-Type"); gc != wc {
						t.Errorf("alias Content-Type = %q, sibling answers %q", gc, wc)
					}
					if got.Body.String() != want.Body.String() {
						t.Errorf("alias body = %q, sibling answers %q", got.Body.String(), want.Body.String())
					}
				})
			}
		}
	}
}

// TestFollowerAppRequests runs every row in followerRequests against a
// fresh handler three times: with the right credential (must match
// row.wantStatus, and for a 200 row must actually serve JSON), with no
// credential, and with a wrong one of the row's own form (both of the
// latter two must get 401 with a plain-text body, never the JSON shape a
// real reading would carry, except on an open endpoint, which answers
// them 200 exactly as it does the right one). A row whose wantStatus is
// 404 is credential-independent by construction — this handler answers 404
// before checkAuth ever runs (see TestUnimplementedPathReturns404BeforeAuth)
// — so only the single request is checked, and row.note carries why that
// app tolerates it.
func TestFollowerAppRequests(t *testing.T) {
	t.Parallel()
	for _, row := range followerRequests {
		t.Run(row.name, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}

			right := httptest.NewRecorder()
			h.ServeHTTP(right, row.request(testToken))
			if right.Code != row.wantStatus {
				t.Fatalf("with the right credential: status = %d, want %d (body: %s)", right.Code, row.wantStatus, right.Body.String())
			}

			if row.wantStatus == http.StatusNotFound {
				if row.note == "" {
					t.Error("a 404 row must state why this app tolerates it (row.note is empty)")
				}
				return
			}
			if ct := right.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("with the right credential: Content-Type = %q, want %q (the row's own claim that this endpoint serves real data)", ct, "application/json")
			}

			for _, c := range []struct {
				name   string
				secret string
			}{
				{"no credential", ""},
				{"wrong credential, same form", "wrong-token"},
			} {
				t.Run(c.name, func(t *testing.T) {
					rec := httptest.NewRecorder()
					h.ServeHTTP(rec, row.request(c.secret))
					if openEndpoints[row.path] {
						if rec.Code != row.wantStatus {
							t.Errorf("open endpoint: status = %d, want %d (body: %s)", rec.Code, row.wantStatus, rec.Body.String())
						}
						return
					}
					if rec.Code != http.StatusUnauthorized {
						t.Errorf("status = %d, want %d (body: %s)", rec.Code, http.StatusUnauthorized, rec.Body.String())
					}
					if ct := rec.Header().Get("Content-Type"); ct == "application/json" {
						t.Errorf("Content-Type = %q on a 401, want the plain-text error body, never the JSON shape a served reading carries", ct)
					}
				})
			}
		})
	}
}
