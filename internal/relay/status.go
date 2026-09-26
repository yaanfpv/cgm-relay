package relay

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/config"
	"github.com/yaanfpv/cgm-relay/internal/poller"
)

// unknownUserAgent is the client tracker's key for a request that carried
// no User-Agent header at all, so it is still counted rather than
// silently dropped.
const unknownUserAgent = "unknown"

// clientTracker records the last time each follower client, identified by
// its User-Agent header, made an authenticated request to the Nightscout
// API. trackClients is its only writer; the status handler is its only
// reader.
type clientTracker struct {
	mu   sync.Mutex
	seen map[string]time.Time
}

func newClientTracker() *clientTracker {
	return &clientTracker{seen: make(map[string]time.Time)}
}

func (t *clientTracker) record(userAgent string, at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.seen[userAgent] = at
}

// snapshot returns a copy of every client's last-seen time, safe for a
// caller to read without racing a concurrent record.
func (t *clientTracker) snapshot() map[string]time.Time {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make(map[string]time.Time, len(t.seen))
	for k, v := range t.seen {
		out[k] = v
	}
	return out
}

// statusCapturingWriter records the status code the wrapped handler
// wrote, defaulting to 200 the way http.ResponseWriter itself does for a
// handler that never calls WriteHeader.
type statusCapturingWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusCapturingWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

// trackClients wraps the Nightscout API handler with User-Agent
// tracking. It records the requesting client's last-seen time in
// tracker, but only for a request that reached an endpoint the handler
// implements with a valid credential: a 401 means checkAuth rejected it,
// and a 404 means the path was never routed to checkAuth at all (an
// unimplemented path, such as a follower app's own capability probe,
// answers 404 before any credential check), so neither tells us a real
// follower app is configured against this relay.
func trackClients(next http.Handler, tracker *clientTracker, now func() time.Time) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sw := &statusCapturingWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		if sw.status == http.StatusUnauthorized || sw.status == http.StatusNotFound {
			return
		}
		userAgent := r.UserAgent()
		if userAgent == "" {
			userAgent = unknownUserAgent
		}
		tracker.record(userAgent, now())
	})
}

// statusResponse is the shape GET /status reports: enough for the menu
// bar app, or a person on a VPS, to see at a glance whether readings are
// fresh and which follower clients are actually polling.
type statusResponse struct {
	// Running is always true: reaching this handler at all means the
	// relay that serves it is up.
	Running         bool       `json:"running"`
	LastFetchTime   *time.Time `json:"last_fetch_time,omitempty"`
	LastReadingTime *time.Time `json:"last_reading_time,omitempty"`
	LastReadingMgDl int        `json:"last_reading_mg_dl,omitempty"`
	SignInFailing   bool       `json:"sign_in_failing"`
	LastError       string     `json:"last_error,omitempty"`
	// Clients maps each follower client's User-Agent to the last time it
	// made an authenticated request.
	Clients map[string]time.Time `json:"clients,omitempty"`
}

// pollerStatus is the subset of *poller.Poller the status handler needs:
// just enough to read a health snapshot, so a test can hand it a fixed
// poller.Status without running a real poller against a real source.
type pollerStatus interface {
	Status() poller.Status
}

// newStatusHandler builds the local status endpoint: a single GET
// /status reporting the poller's health and the clients tracker has
// seen. Binding the listener to loopback is not enough on its own: a
// page open in the user's browser can retarget its own domain to
// 127.0.0.1 (DNS rebinding) and issue a same-origin fetch that still
// reaches a loopback listener, carrying that domain as the request's
// Host. requireLoopbackHost closes that gap by checking Host on every
// request, in addition to the listener's own bind address.
func newStatusHandler(p pollerStatus, tracker *clientTracker) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		s := p.Status()
		resp := statusResponse{
			Running:         true,
			SignInFailing:   s.SignInFailing,
			LastError:       s.LastError,
			LastReadingMgDl: s.LastReadingMgDl,
			Clients:         tracker.snapshot(),
		}
		if !s.LastFetchTime.IsZero() {
			resp.LastFetchTime = &s.LastFetchTime
		}
		if !s.LastReadingTime.IsZero() {
			resp.LastReadingTime = &s.LastReadingTime
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})
	return requireLoopbackHost(mux)
}

// requireLoopbackHost refuses, with 403 and no reading data in the body,
// any request whose Host does not itself resolve to a loopback address.
// An ordinary HTTP client (Go's own included) sends the dialled
// host:port as Host, so a direct request to the loopback listener
// passes through unchanged; only a request carrying some other name --
// exactly what a DNS-rebinding page sends -- is refused.
func requireLoopbackHost(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !config.IsLoopbackAddr(r.Host) {
			http.Error(w, "relay: status endpoint refuses a non-loopback Host", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}
