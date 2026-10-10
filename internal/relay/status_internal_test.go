package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/config"
	"github.com/yaanfpv/cgm-relay/internal/nightscout"
	"github.com/yaanfpv/cgm-relay/internal/pairing"
	"github.com/yaanfpv/cgm-relay/internal/poller"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// fixedNow returns a now func that always reports t, so a test can assert
// on an exact recorded time instead of racing the wall clock.
func fixedNow(t time.Time) func() time.Time {
	return func() time.Time { return t }
}

// fakePollerStatus is a pollerStatus that always reports a fixed
// snapshot, so the status handler's shape can be tested without running
// a real poller against a real source.
type fakePollerStatus struct {
	status poller.Status
}

func (f fakePollerStatus) Status() poller.Status { return f.status }

// TestClientTrackerRecordsOnlyAuthenticatedRequests checks the exclusion
// rule directly against trackClients: a request the wrapped handler
// answers with 401 (rejected credential), 404 (an unimplemented path,
// never even reaching a credential check), or from an endpoint that needs
// no credential at all is never recorded, and every other status code is,
// keyed by the request's User-Agent.
func TestClientTrackerRecordsOnlyAuthenticatedRequests(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name        string
		path        string
		status      int
		userAgent   string
		wantTracked bool
		wantKey     string
	}{
		{name: "unauthenticated", status: http.StatusUnauthorized, userAgent: "xDrip4iOS/1.0", wantTracked: false},
		{name: "an unimplemented path", status: http.StatusNotFound, userAgent: "Nightguard/1.0", wantTracked: false},
		{name: "authenticated ok", status: http.StatusOK, userAgent: "LoopFollow/1.0", wantTracked: true, wantKey: "LoopFollow/1.0"},
		{name: "authenticated but a bad request", status: http.StatusBadRequest, userAgent: "Nightguard/1.0", wantTracked: true, wantKey: "Nightguard/1.0"},
		{name: "the credential-free status check", path: "/api/v1/status.json", status: http.StatusOK, userAgent: "xDrip4iOS/1.0", wantTracked: false},
		{name: "the credential-free page", path: "/", status: http.StatusOK, userAgent: "Mozilla/5.0", wantTracked: false},
		{name: "authenticated with no user agent", status: http.StatusOK, userAgent: "", wantTracked: true, wantKey: unknownUserAgent},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			tracker := newClientTracker()
			now := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
			inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(c.status)
			})
			wrapped := trackClients(inner, tracker, fixedNow(now))

			path := c.path
			if path == "" {
				path = "/api/v1/entries.json"
			}
			req := httptest.NewRequest(http.MethodGet, path, nil)
			if c.userAgent != "" {
				req.Header.Set("User-Agent", c.userAgent)
			}
			rec := httptest.NewRecorder()
			wrapped.ServeHTTP(rec, req)

			if rec.Code != c.status {
				t.Fatalf("status = %d, want %d", rec.Code, c.status)
			}

			seen := tracker.snapshot()
			if c.wantTracked {
				got, ok := seen[c.wantKey]
				if !ok {
					t.Fatalf("client %q not recorded, seen = %v", c.wantKey, seen)
				}
				if !got.Equal(now) {
					t.Errorf("recorded time = %v, want %v", got, now)
				}
				if len(seen) != 1 {
					t.Errorf("len(seen) = %d, want 1", len(seen))
				}
			} else if len(seen) != 0 {
				t.Errorf("an unauthenticated request was tracked: %v", seen)
			}
		})
	}
}

// TestClientTrackerCapsAndEvictsTheOldest checks the tracker's cap
// directly: recording 300 distinct User-Agents leaves at most
// maxTrackedClients entries, the most recently seen client present, and
// the longest-silent one gone. It also checks that refreshing an
// existing key's own last-seen time is a plain update, never an
// eviction-triggering growth of the map.
func TestClientTrackerCapsAndEvictsTheOldest(t *testing.T) {
	t.Parallel()
	tracker := newClientTracker()
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)

	const total = 300
	for i := 0; i < total; i++ {
		tracker.record(fmt.Sprintf("client-%d", i), base.Add(time.Duration(i)*time.Second))
	}

	seen := tracker.snapshot()
	if len(seen) != maxTrackedClients {
		t.Fatalf("len(seen) = %d, want %d", len(seen), maxTrackedClients)
	}

	newestKey := fmt.Sprintf("client-%d", total-1)
	if _, ok := seen[newestKey]; !ok {
		t.Errorf("the most recently seen client (%q) was evicted, want it to survive", newestKey)
	}
	oldestKey := "client-0"
	if _, ok := seen[oldestKey]; ok {
		t.Errorf("the longest-silent client (%q) survived, want it evicted", oldestKey)
	}

	// The oldest surviving client is the one just past the eviction
	// cutoff: total - maxTrackedClients clients were evicted in
	// insertion order, since every insert's timestamp strictly increases.
	oldestSurvivor := fmt.Sprintf("client-%d", total-maxTrackedClients)
	if _, ok := seen[oldestSurvivor]; !ok {
		t.Fatalf("expected oldest survivor %q not present, seen has %d entries", oldestSurvivor, len(seen))
	}

	refreshedAt := base.Add(time.Duration(total+100) * time.Second)
	tracker.record(oldestSurvivor, refreshedAt)
	seen = tracker.snapshot()
	if len(seen) != maxTrackedClients {
		t.Errorf("re-recording an existing client changed len(seen) to %d, want %d (an update must never evict)", len(seen), maxTrackedClients)
	}
	if !seen[oldestSurvivor].Equal(refreshedAt) {
		t.Errorf("re-recording %q did not update its last-seen time: got %v, want %v", oldestSurvivor, seen[oldestSurvivor], refreshedAt)
	}
}

// TestStatusHandlerReportsPollerAndClients checks that the handler
// carries the poller's last fetch, last reading, sign-in state and last
// error exactly as its Status reports them, plus every client the
// tracker has seen.
func TestStatusHandlerReportsPollerAndClients(t *testing.T) {
	t.Parallel()
	lastFetch := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	lastReading := lastFetch.Add(-30 * time.Second)
	fake := fakePollerStatus{status: poller.Status{
		LastFetchTime:    lastFetch,
		LastReadingTime:  lastReading,
		LastReadingMgDl:  145,
		LastReadingTrend: cgm.TrendFortyFiveUp,
		SignInFailing:    true,
		LastError:        "sign-in failed",
	}}

	tracker := newClientTracker()
	seenAt := time.Date(2026, 6, 1, 11, 59, 0, 0, time.UTC)
	tracker.record("xDrip4iOS/1.0", seenAt)
	tracker.record("LoopFollow/1.0", seenAt.Add(time.Minute))
	lanReadings := newClientTracker()
	lanSeenAt := seenAt.Add(2 * time.Minute)
	lanReadings.record("xDrip4iOS/1.0", lanSeenAt)

	h := newStatusHandler(fake, tracker, lanReadings, pairing.NewStore(nil), "")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status", nil)
	req.Host = "127.0.0.1:1338" // this test is about the response shape, not the Host gate
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	var got statusResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode /status: %v", err)
	}
	if !got.Running {
		t.Error("running = false, want true")
	}
	if got.LastFetchTime == nil || !got.LastFetchTime.Equal(lastFetch) {
		t.Errorf("last_fetch_time = %v, want %v", got.LastFetchTime, lastFetch)
	}
	if got.LastReadingTime == nil || !got.LastReadingTime.Equal(lastReading) {
		t.Errorf("last_reading_time = %v, want %v", got.LastReadingTime, lastReading)
	}
	if got.LastReadingMgDl != 145 {
		t.Errorf("last_reading_mg_dl = %d, want 145", got.LastReadingMgDl)
	}
	if got.LastReadingTrend != "FortyFiveUp" {
		t.Errorf("last_reading_trend = %q, want FortyFiveUp", got.LastReadingTrend)
	}
	if !got.SignInFailing {
		t.Error("sign_in_failing = false, want true")
	}
	if got.LastError != "sign-in failed" {
		t.Errorf("last_error = %q, want %q", got.LastError, "sign-in failed")
	}
	if len(got.Clients) != 2 {
		t.Fatalf("len(clients) = %d, want 2 (body: %s)", len(got.Clients), rec.Body.String())
	}
	if !got.Clients["xDrip4iOS/1.0"].Equal(seenAt) {
		t.Errorf("clients[xDrip4iOS/1.0] = %v, want %v", got.Clients["xDrip4iOS/1.0"], seenAt)
	}
	if !got.Clients["LoopFollow/1.0"].Equal(seenAt.Add(time.Minute)) {
		t.Errorf("clients[LoopFollow/1.0] = %v, want %v", got.Clients["LoopFollow/1.0"], seenAt.Add(time.Minute))
	}
	if len(got.LANReadingClients) != 1 || !got.LANReadingClients["xDrip4iOS/1.0"].Equal(lanSeenAt) {
		t.Errorf("lan_reading_clients = %v, want only xDrip4iOS/1.0 at %v (body: %s)", got.LANReadingClients, lanSeenAt, rec.Body.String())
	}
}

// TestStatusHandlerOmitsUnsetFields checks that a poller which has never
// completed a fetch reports no last_fetch_time or last_reading_time,
// rather than the zero time formatted as if it meant something.
func TestStatusHandlerOmitsUnsetFields(t *testing.T) {
	t.Parallel()
	h := newStatusHandler(fakePollerStatus{}, newClientTracker(), newClientTracker(), pairing.NewStore(nil), "")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status", nil)
	req.Host = "127.0.0.1:1338" // this test is about the response shape, not the Host gate
	h.ServeHTTP(rec, req)

	var raw map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode /status: %v", err)
	}
	if _, present := raw["last_fetch_time"]; present {
		t.Error(`"last_fetch_time" is present before any fetch has completed`)
	}
	if _, present := raw["last_reading_time"]; present {
		t.Error(`"last_reading_time" is present before any reading has been stored`)
	}
	if _, present := raw["last_reading_trend"]; present {
		t.Error(`"last_reading_trend" is present before any reading has been stored`)
	}
	if _, present := raw["lan_reading_clients"]; present {
		t.Error(`"lan_reading_clients" is present before any client has fetched readings over a LAN listener`)
	}
}

// TestStatusHandlerOmitsTrendTheDeviceDidNotCompute checks that a stored
// reading with no computed trend carries no last_reading_trend, rather than
// a direction name that would render as an arrow.
func TestStatusHandlerOmitsTrendTheDeviceDidNotCompute(t *testing.T) {
	t.Parallel()
	for _, trend := range []cgm.Trend{cgm.TrendUnknown, cgm.TrendNotComputable} {
		fake := fakePollerStatus{status: poller.Status{
			LastReadingTime:  time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC),
			LastReadingMgDl:  120,
			LastReadingTrend: trend,
		}}
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/status", nil)
		req.Host = "127.0.0.1:1338"
		newStatusHandler(fake, newClientTracker(), newClientTracker(), pairing.NewStore(nil), "").ServeHTTP(rec, req)

		var raw map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatalf("decode /status: %v", err)
		}
		if v, present := raw["last_reading_trend"]; present {
			t.Errorf("trend %d: last_reading_trend = %v, want it omitted", trend, v)
		}
	}
}

// TestStatusHandlerRequiresLoopbackHost checks the handler's own Host
// check, which exists because binding the status listener to loopback is
// not enough on its own: a page open in the user's browser can retarget
// its own domain to 127.0.0.1 via DNS rebinding and issue a same-origin
// fetch that still reaches the listener, carrying that domain as Host.
// The handler must refuse, with 403 and no reading data in the body, any
// request whose Host does not itself resolve to loopback, and must still
// answer a request carrying the dialled loopback address (what an
// ordinary client, including Go's own http.Client, actually sends).
func TestStatusHandlerRequiresLoopbackHost(t *testing.T) {
	t.Parallel()
	fake := fakePollerStatus{status: poller.Status{LastReadingMgDl: 145}}
	h := newStatusHandler(fake, newClientTracker(), newClientTracker(), pairing.NewStore(nil), "")

	cases := []struct {
		host       string
		wantStatus int
	}{
		{host: "evil.example", wantStatus: http.StatusForbidden},
		{host: "evil.example:1338", wantStatus: http.StatusForbidden},
		{host: "192.168.1.5:1338", wantStatus: http.StatusForbidden},
		{host: "", wantStatus: http.StatusForbidden},
		{host: "127.0.0.1:1338", wantStatus: http.StatusOK},
		{host: "localhost:1338", wantStatus: http.StatusOK},
		{host: "[::1]:1338", wantStatus: http.StatusOK},
	}
	for _, c := range cases {
		t.Run(c.host, func(t *testing.T) {
			t.Parallel()
			req := httptest.NewRequest(http.MethodGet, "/status", nil)
			req.Host = c.host
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)

			if rec.Code != c.wantStatus {
				t.Fatalf("Host %q: status = %d, want %d (body: %s)", c.host, rec.Code, c.wantStatus, rec.Body.String())
			}
			if c.wantStatus == http.StatusForbidden {
				if ContainsValue(rec.Body.String(), "145") {
					t.Errorf("Host %q: a refused request's body carries the reading value: %s", c.host, rec.Body.String())
				}
				var asJSON map[string]any
				if err := json.Unmarshal(rec.Body.Bytes(), &asJSON); err == nil {
					t.Errorf("Host %q: a refused request's body still decodes as the status JSON shape: %s", c.host, rec.Body.String())
				}
			}
		})
	}
}

const (
	testStatusSecret = "per-launch-secret-0123456789abcdef"
	testMintBody     = `{"apps":[{"name":"A","steps":["s"],"fields":[{"label":"URL","value":"{token}"}],"links":[]}]}`
)

// statusRequest sends one request through h as a loopback caller carrying
// the given secret header value ("" sends no header at all).
func statusRequest(h http.Handler, method, path, secret string) *httptest.ResponseRecorder {
	var body *strings.Reader
	if method == http.MethodPost {
		body = strings.NewReader(testMintBody)
	} else {
		body = strings.NewReader("")
	}
	req := httptest.NewRequest(method, path, body)
	req.Host = "127.0.0.1:1338"
	req.RemoteAddr = "127.0.0.1:50000"
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
	}
	if secret != "" {
		req.Header.Set(config.StatusSecretHeader, secret)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// TestStatusHandlerSecret checks the caller authentication the loopback,
// Host and peer checks cannot give: with a secret configured, /status and
// /pairing both refuse a missing or wrong secret with the same fixed body
// and hand back no code; without one, /status stays open and /pairing is
// absent even for a caller that sends a secret header.
func TestStatusHandlerSecret(t *testing.T) {
	t.Parallel()
	fake := fakePollerStatus{status: poller.Status{LastReadingMgDl: 145}}

	cases := []struct {
		name       string
		configured string
		method     string
		path       string
		sent       string
		wantStatus int
		wantMint   bool
	}{
		{name: "mint with the right secret", configured: testStatusSecret, method: http.MethodPost, path: "/pairing", sent: testStatusSecret, wantStatus: http.StatusOK, wantMint: true},
		{name: "mint with no secret", configured: testStatusSecret, method: http.MethodPost, path: "/pairing", wantStatus: http.StatusUnauthorized},
		{name: "mint with a wrong secret", configured: testStatusSecret, method: http.MethodPost, path: "/pairing", sent: "wrong-secret-0123456789abcdef", wantStatus: http.StatusUnauthorized},
		{name: "mint with a prefix of the secret", configured: testStatusSecret, method: http.MethodPost, path: "/pairing", sent: testStatusSecret[:len(testStatusSecret)-1], wantStatus: http.StatusUnauthorized},
		{name: "mint with no secret configured", method: http.MethodPost, path: "/pairing", wantStatus: http.StatusNotFound},
		{name: "mint with no secret configured, a secret sent", method: http.MethodPost, path: "/pairing", sent: testStatusSecret, wantStatus: http.StatusNotFound},
		{name: "status with the right secret", configured: testStatusSecret, method: http.MethodGet, path: "/status", sent: testStatusSecret, wantStatus: http.StatusOK},
		{name: "status with no secret", configured: testStatusSecret, method: http.MethodGet, path: "/status", wantStatus: http.StatusUnauthorized},
		{name: "status with a wrong secret", configured: testStatusSecret, method: http.MethodGet, path: "/status", sent: "wrong-secret-0123456789abcdef", wantStatus: http.StatusUnauthorized},
		{name: "status with no secret configured", method: http.MethodGet, path: "/status", wantStatus: http.StatusOK},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			pairings := pairing.NewStore(nil)
			h := newStatusHandler(fake, newClientTracker(), newClientTracker(), pairings, c.configured)
			rec := statusRequest(h, c.method, c.path, c.sent)

			if rec.Code != c.wantStatus {
				t.Fatalf("status = %d, want %d (body: %s)", rec.Code, c.wantStatus, rec.Body.String())
			}
			if c.wantStatus == http.StatusUnauthorized {
				if want := "relay: status endpoint needs the app's secret\n"; rec.Body.String() != want {
					t.Errorf("body = %q, want the fixed %q", rec.Body.String(), want)
				}
			}
			if c.wantMint {
				var resp struct {
					Code string `json:"code"`
				}
				if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
					t.Fatalf("decode mint response: %v", err)
				}
				if _, ok := pairings.Lookup(resp.Code); !ok {
					t.Error("the minted code does not resolve")
				}
			} else if c.path == "/pairing" {
				var resp struct {
					Code string `json:"code"`
				}
				if json.Unmarshal(rec.Body.Bytes(), &resp) == nil && resp.Code != "" {
					t.Errorf("a refused mint still answered with a code: %s", rec.Body.String())
				}
			}
		})
	}
}

// TestClientTrackerTruncatesLongUserAgents checks that the key the tracker
// stores is cut at maxTrackedUserAgentBytes, so a client sending a huge
// User-Agent cannot make 256 tracked clients hold huge keys.
func TestClientTrackerTruncatesLongUserAgents(t *testing.T) {
	t.Parallel()
	tracker := newClientTracker()
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {})
	wrapped := trackClients(inner, tracker, fixedNow(time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/entries.json", nil)
	req.Header.Set("User-Agent", strings.Repeat("a", 5000))
	wrapped.ServeHTTP(httptest.NewRecorder(), req)

	seen := tracker.snapshot()
	if len(seen) != 1 {
		t.Fatalf("len(seen) = %d, want 1", len(seen))
	}
	for key := range seen {
		if len(key) != maxTrackedUserAgentBytes {
			t.Errorf("stored key is %d bytes, want %d", len(key), maxTrackedUserAgentBytes)
		}
	}
}

// TestStartServerAppliesTimeouts checks that every server Run starts
// carries a non-zero ReadHeaderTimeout and its sibling timeouts, never
// the http.Server zero value, which would let a slow or hung client block
// a connection forever.
func TestStartServerAppliesTimeouts(t *testing.T) {
	t.Parallel()
	rs, err := startServer("127.0.0.1:0", http.NotFoundHandler())
	if err != nil {
		t.Fatalf("startServer: %v", err)
	}
	defer rs.shutdown()

	if rs.srv.ReadHeaderTimeout <= 0 {
		t.Error("ReadHeaderTimeout is not set")
	}
	if rs.srv.ReadTimeout <= 0 {
		t.Error("ReadTimeout is not set")
	}
	if rs.srv.WriteTimeout <= 0 {
		t.Error("WriteTimeout is not set")
	}
	if rs.srv.IdleTimeout <= 0 {
		t.Error("IdleTimeout is not set")
	}
}

// ContainsValue reports whether text carries value, a plain decimal
// numeral, as a standalone number rather than as a digit run inside some
// other number: it is exported so relay_test's own leak checks can share
// it. A match only counts when neither the character right before it nor
// the one right after it is itself an ASCII digit, so a value logged next
// to an ephemeral port (which can contain any digit run) never trips it,
// while the same digits printed next to a unit, a colon, or at either
// edge of text still do.
func ContainsValue(text, value string) bool {
	for start := 0; ; {
		idx := strings.Index(text[start:], value)
		if idx == -1 {
			return false
		}
		at := start + idx
		before, after := at-1, at+len(value)
		precededByDigit := before >= 0 && isASCIIDigit(text[before])
		followedByDigit := after < len(text) && isASCIIDigit(text[after])
		if !precededByDigit && !followedByDigit {
			return true
		}
		start = at + 1
	}
}

func isASCIIDigit(b byte) bool {
	return b >= '0' && b <= '9'
}

// TestContainsValue proves ContainsValue's whole reason for existing:
// unlike a bare strings.Contains, it does not trip on a value's digits
// turning up by coincidence inside an unrelated, longer number, while it
// still catches the same value printed next to a unit, a colon, or
// nothing at all.
func TestContainsValue(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		text string
		want bool
	}{
		{name: "value's digits trail inside a longer port number", text: "serving the status endpoint on 127.0.0.1:51112", want: false},
		{name: "value's digits lead inside a longer port number", text: "serving the status endpoint on 127.0.0.1:49111", want: false},
		{name: "value printed with a space and a unit", text: "reading 111 mg/dL", want: true},
		{name: "value printed right against a unit with no space", text: "reading 111mg/dL", want: true},
		{name: "value printed right after a colon", text: "last_reading_mg_dl:111", want: true},
		{name: "value is the entire text", text: "111", want: true},
		{name: "value absent entirely", text: "serving the Nightscout API on 127.0.0.1:54321", want: false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			if got := ContainsValue(c.text, "111"); got != c.want {
				t.Errorf("ContainsValue(%q, %q) = %v, want %v", c.text, "111", got, c.want)
			}
		})
	}
}

// fakeReadings is a nightscout.ReadingRange holding a fixed set of readings.
type fakeReadings struct {
	readings []cgm.Reading
}

func (f fakeReadings) Range(_ context.Context, q store.RangeQuery) ([]cgm.Reading, error) {
	if q.Limit > 0 && len(f.readings) > q.Limit {
		return f.readings[:q.Limit], nil
	}
	return f.readings, nil
}

const lanTestToken = "lan-reading-token-0123456789"

// lanFetch sends one GET for target through handler as userAgent and
// returns the status code. A "{token}" in target is replaced by the real
// token; header, when not empty, is sent as the api-secret header.
func lanFetch(handler http.Handler, target, userAgent, header string) int {
	req := httptest.NewRequest(http.MethodGet, strings.ReplaceAll(target, "{token}", lanTestToken), nil)
	if userAgent != "" {
		req.Header.Set("User-Agent", userAgent)
	}
	if header != "" {
		req.Header.Set("api-secret", header)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec.Code
}

func newLANTestHandler(t *testing.T, readings []cgm.Reading, tracker *clientTracker, now func() time.Time) http.Handler {
	t.Helper()
	ns, err := nightscout.New(fakeReadings{readings: readings}, lanTestToken, nil)
	if err != nil {
		t.Fatalf("nightscout.New: %v", err)
	}
	return trackLANReadings(ns, tracker, now)
}

// TestLANReadingTrackerRecordsOnlyRequestsAnsweredWithReadings drives the
// real Nightscout handler through trackLANReadings: only a request that
// carried a valid credential and was answered with at least one reading is
// recorded, whichever endpoint or credential form it used.
func TestLANReadingTrackerRecordsOnlyRequestsAnsweredWithReadings(t *testing.T) {
	t.Parallel()
	one := []cgm.Reading{{Time: time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC), MgDl: 120, Trend: cgm.TrendFlat, Source: "test"}}
	cases := []struct {
		name     string
		readings []cgm.Reading
		target   string
		header   string
		want     bool
	}{
		{name: "entries with a token", readings: one, target: "/api/v1/entries.json?count=10&token={token}", want: true},
		{name: "sgv with a token", readings: one, target: "/api/v1/entries/sgv.json?token={token}", want: true},
		{name: "current with a token", readings: one, target: "/api/v1/entries/current.json?token={token}", want: true},
		{name: "entries with the api-secret header", readings: one, target: "/api/v1/entries.json", header: lanTestToken, want: true},
		{name: "no token", readings: one, target: "/api/v1/entries.json?count=10"},
		{name: "a wrong token", readings: one, target: "/api/v1/entries.json?token=not-the-token"},
		{name: "a wrong api-secret header", readings: one, target: "/api/v1/entries.json", header: "not-the-token"},
		{name: "an empty store", target: "/api/v1/entries.json?token={token}"},
		{name: "an empty store on current", target: "/api/v1/entries/current.json?token={token}"},
		{name: "a count of zero", readings: one, target: "/api/v1/entries.json?count=0&token={token}"},
		{name: "a malformed count", readings: one, target: "/api/v1/entries.json?count=x&token={token}"},
		{name: "the status check", readings: one, target: "/api/v1/status.json?token={token}"},
		{name: "the profile", readings: one, target: "/api/v1/profile?token={token}"},
		{name: "the treatments list", readings: one, target: "/api/v1/treatments.json?token={token}"},
		{name: "an unimplemented path", readings: one, target: "/api/v3/version?token={token}"},
		{name: "the root page", readings: one, target: "/"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			tracker := newClientTracker()
			now := time.Date(2026, 6, 1, 12, 5, 0, 0, time.UTC)
			h := newLANTestHandler(t, c.readings, tracker, fixedNow(now))

			lanFetch(h, c.target, "LoopFollow/2.0", c.header)

			seen := tracker.snapshot()
			if !c.want {
				if len(seen) != 0 {
					t.Fatalf("recorded %v, want nothing", seen)
				}
				return
			}
			if got, ok := seen["LoopFollow/2.0"]; !ok || !got.Equal(now) || len(seen) != 1 {
				t.Fatalf("recorded %v, want only LoopFollow/2.0 at %v", seen, now)
			}
		})
	}
}

// TestLANReadingTrackerMovesForwardAndCleansTheUserAgent checks that a
// later fetch replaces the recorded time, that the User-Agent is kept as
// sent apart from control characters and the length cut, that a fetch with
// no User-Agent is still recorded, and that /status carries no part of the
// token or the query string.
func TestLANReadingTrackerMovesForwardAndCleansTheUserAgent(t *testing.T) {
	t.Parallel()
	one := []cgm.Reading{{Time: time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC), MgDl: 120, Trend: cgm.TrendFlat, Source: "test"}}
	tracker := newClientTracker()
	current := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	h := newLANTestHandler(t, one, tracker, func() time.Time { return current })
	target := "/api/v1/entries.json?count=3&token={token}"

	lanFetch(h, target, "xDrip4iOS/1.0", "")
	first := tracker.snapshot()["xDrip4iOS/1.0"]
	if !first.Equal(current) {
		t.Fatalf("first fetch recorded %v, want %v", first, current)
	}
	current = current.Add(5 * time.Minute)
	lanFetch(h, target, "xDrip4iOS/1.0", "")
	if second := tracker.snapshot()["xDrip4iOS/1.0"]; !second.Equal(current) || !second.After(first) {
		t.Errorf("later fetch recorded %v, want %v, after %v", second, current, first)
	}

	// Control characters are removed; the rest is kept as sent. The header
	// value is set on the request directly, since a client library would
	// refuse to send the control characters at all.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/entries.json?token="+lanTestToken, nil)
	req.Header["User-Agent"] = []string{"Nightguard\x00/\x1b[31m1.0\t\u0085 \u00e9"}
	h.ServeHTTP(httptest.NewRecorder(), req)
	if _, ok := tracker.snapshot()["Nightguard/[31m1.0 \u00e9"]; !ok {
		t.Errorf("control characters were not removed or the rest was altered: %q", tracker.snapshot())
	}

	long := strings.Repeat("\u00e9", 500)
	lanFetch(h, target, long, "")
	if _, ok := tracker.snapshot()[strings.Repeat("\u00e9", maxLANUserAgentRunes)]; !ok {
		t.Errorf("a %d-character User-Agent was not cut to %d characters: %q", 500, maxLANUserAgentRunes, tracker.snapshot())
	}

	lanFetch(h, target, "", "")
	if _, ok := tracker.snapshot()[unknownUserAgent]; !ok {
		t.Errorf("a fetch with no User-Agent was not recorded as %q: %v", unknownUserAgent, tracker.snapshot())
	}

	status := newStatusHandler(fakePollerStatus{}, newClientTracker(), tracker, pairing.NewStore(nil), "")
	rec := httptest.NewRecorder()
	statusReq := httptest.NewRequest(http.MethodGet, "/status", nil)
	statusReq.Host = "127.0.0.1:1338"
	status.ServeHTTP(rec, statusReq)
	body := rec.Body.String()
	for _, leaked := range []string{lanTestToken, "token=", "count=3", "?"} {
		if strings.Contains(body, leaked) {
			t.Errorf("/status carries %q: %s", leaked, body)
		}
	}
	var got statusResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode /status: %v", err)
	}
	if len(got.LANReadingClients) != 4 {
		t.Errorf("lan_reading_clients = %v, want 4 entries", got.LANReadingClients)
	}
}
