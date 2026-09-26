package relay

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/poller"
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
// answers with 401 (rejected credential) or 404 (an unimplemented path,
// never even reaching a credential check) is never recorded, and every
// other status code is, keyed by the request's User-Agent.
func TestClientTrackerRecordsOnlyAuthenticatedRequests(t *testing.T) {
	cases := []struct {
		name        string
		status      int
		userAgent   string
		wantTracked bool
		wantKey     string
	}{
		{name: "unauthenticated", status: http.StatusUnauthorized, userAgent: "xDrip4iOS/1.0", wantTracked: false},
		{name: "an unimplemented path", status: http.StatusNotFound, userAgent: "Nightguard/1.0", wantTracked: false},
		{name: "authenticated ok", status: http.StatusOK, userAgent: "LoopFollow/1.0", wantTracked: true, wantKey: "LoopFollow/1.0"},
		{name: "authenticated but a bad request", status: http.StatusBadRequest, userAgent: "Nightguard/1.0", wantTracked: true, wantKey: "Nightguard/1.0"},
		{name: "authenticated with no user agent", status: http.StatusOK, userAgent: "", wantTracked: true, wantKey: unknownUserAgent},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tracker := newClientTracker()
			now := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
			inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(c.status)
			})
			wrapped := trackClients(inner, tracker, fixedNow(now))

			req := httptest.NewRequest(http.MethodGet, "/api/v1/entries.json", nil)
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

// TestStatusHandlerReportsPollerAndClients checks that the handler
// carries the poller's last fetch, last reading, sign-in state and last
// error exactly as its Status reports them, plus every client the
// tracker has seen.
func TestStatusHandlerReportsPollerAndClients(t *testing.T) {
	lastFetch := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	lastReading := lastFetch.Add(-30 * time.Second)
	fake := fakePollerStatus{status: poller.Status{
		LastFetchTime:   lastFetch,
		LastReadingTime: lastReading,
		LastReadingMgDl: 145,
		SignInFailing:   true,
		LastError:       "sign-in failed",
	}}

	tracker := newClientTracker()
	seenAt := time.Date(2026, 6, 1, 11, 59, 0, 0, time.UTC)
	tracker.record("xDrip4iOS/1.0", seenAt)
	tracker.record("LoopFollow/1.0", seenAt.Add(time.Minute))

	h := newStatusHandler(fake, tracker)
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
}

// TestStatusHandlerOmitsUnsetFields checks that a poller which has never
// completed a fetch reports no last_fetch_time or last_reading_time,
// rather than the zero time formatted as if it meant something.
func TestStatusHandlerOmitsUnsetFields(t *testing.T) {
	h := newStatusHandler(fakePollerStatus{}, newClientTracker())
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
	fake := fakePollerStatus{status: poller.Status{LastReadingMgDl: 145}}
	h := newStatusHandler(fake, newClientTracker())

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
			req := httptest.NewRequest(http.MethodGet, "/status", nil)
			req.Host = c.host
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)

			if rec.Code != c.wantStatus {
				t.Fatalf("Host %q: status = %d, want %d (body: %s)", c.host, rec.Code, c.wantStatus, rec.Body.String())
			}
			if c.wantStatus == http.StatusForbidden {
				if strings.Contains(rec.Body.String(), "145") {
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

// TestStartServerAppliesTimeouts checks that every server Run starts
// carries a non-zero ReadHeaderTimeout and its sibling timeouts, never
// the http.Server zero value, which would let a slow or hung client block
// a connection forever.
func TestStartServerAppliesTimeouts(t *testing.T) {
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
