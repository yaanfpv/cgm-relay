// Package llufake is an in-process fake LibreLinkUp server for tests. It
// implements enough of the sign-in, connections, and graph endpoints to
// drive a librelinkup.Source through every path that Source needs to
// handle, and it records every request it receives so a test can assert on
// header presence and call order.
package llufake

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// dynamicReadingFormat matches librelinkup's own FactoryTimestamp layout
// ("2/13/2020 5:29:23 PM"-shaped), so a dynamic-mode reading (see SetMode)
// decodes the same way a real LibreLinkUp response would.
const dynamicReadingFormat = "1/2/2006 3:04:05 PM"

// staleReadingAge is how far in the past SetMode("stale") timestamps its
// one reading: comfortably past MenuDisplayState's five-minute freshness
// window, so it reads as stale rather than sitting right on the boundary.
const staleReadingAge = 10 * time.Minute

// dynamicReadingMgDl is the glucose value every dynamic-mode reading
// carries; SetMode's modes exist to drive the reading's age and the
// sign-in outcome, never this value, so one fixed, plausible number is
// enough.
const dynamicReadingMgDl = 100

// Measurement is one glucose reading as the fake's graph endpoint reports
// it, in LibreLinkUp's own JSON shape. FactoryTimestamp and Timestamp are
// pre-formatted strings ("M/d/yyyy h:mm:ss a") so a test can set them to
// different clocks and prove a Source reads the right one.
type Measurement struct {
	FactoryTimestamp string
	Timestamp        string
	ValueInMgPerDl   float64
	TrendArrow       int
}

// Request is one HTTP request the fake received, recorded for assertions
// on header presence and call order.
type Request struct {
	Method string
	Path   string
	Header http.Header
}

// Server is an in-process fake LibreLinkUp server.
type Server struct {
	// URL is the fake's base URL, usable with librelinkup.WithBaseURL.
	URL string

	srv *httptest.Server

	mu sync.Mutex

	requests []Request

	userID string

	// loginJSONStatus is the next sign-in's JSON status field: 0 (ok), 2
	// (bad credentials), or 4 (terms not accepted). It is consumed once
	// the next sign-in answers with it.
	loginJSONStatus int

	// redirectRegion, when set, makes the next sign-in answer with a
	// region redirect instead of a token. Consumed once.
	redirectRegion string

	// loginHTTPStatus, when nonzero, makes the next sign-in answer with
	// this raw HTTP status (e.g. 429) instead of a JSON body. Consumed
	// once.
	loginHTTPStatus int
	loginRetryAfter string

	tokenSeq int
	// validToken is the token the fake currently accepts on the
	// connections and graph endpoints.
	validToken string
	// tokenUsesLeft is how many more times validToken may be used
	// successfully; negative means unlimited.
	tokenUsesLeft int
	// nextTokenLimit is the tokenUsesLeft value the NEXT minted token
	// starts with; RejectTokenAfter sets this, and it resets to unlimited
	// once applied, so only the token issued right after the call is
	// affected.
	nextTokenLimit int

	patientIDs []string

	// graphHTTPStatus, when nonzero, makes the next graph request answer
	// with this raw HTTP status instead of a JSON body. Consumed once.
	graphHTTPStatus int
	graphRetryAfter string

	current *Measurement
	history []Measurement

	// mode is the standalone fake's (cmd/llufake) own runtime control:
	// "", "fresh", "stale", or "reject". The Go test suite never sets
	// it and drives the fake through the setters above instead, so
	// every behaviour they exercise is unchanged by its presence.
	mode string
}

// NewServer starts a fake LibreLinkUp server with a default happy-path
// configuration: sign-in succeeds for user id "fake-user", the account has
// one connection ("fake-patient"), and the graph endpoint returns no
// measurements until SetGraph or SetMode is called. The caller owns its
// lifecycle and must call Close; New, below, is the test-scoped wrapper
// most callers want instead.
func NewServer() *Server {
	s := &Server{
		userID:         "fake-user",
		tokenUsesLeft:  -1,
		nextTokenLimit: -1,
		patientIDs:     []string{"fake-patient"},
	}
	s.srv = httptest.NewServer(http.HandlerFunc(s.handle))
	s.URL = s.srv.URL
	return s
}

// New starts a fake LibreLinkUp server the same way NewServer does, closed
// automatically when the test ends.
func New(t testing.TB) *Server {
	s := NewServer()
	t.Cleanup(s.Close)
	return s
}

// Close shuts down the fake early, so a test can simulate a network
// failure by closing it before a Source calls it. Safe to call more than
// once.
func (s *Server) Close() { s.srv.Close() }

// SetUserID sets the id returned as the signed-in user, used to derive the
// Account-Id header the fake expects on every authenticated request.
func (s *Server) SetUserID(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.userID = id
}

// RejectCredentials makes the next sign-in answer as LibreLinkUp does for
// a wrong email or password (JSON status 2).
func (s *Server) RejectCredentials() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loginJSONStatus = 2
}

// RequireTermsAcceptance makes the next sign-in answer as LibreLinkUp does
// when the account must accept new terms before signing in (JSON status
// 4).
func (s *Server) RequireTermsAcceptance() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loginJSONStatus = 4
}

// RedirectTo makes the next sign-in answer with a redirect to region
// instead of a token, exactly once.
func (s *Server) RedirectTo(region string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.redirectRegion = region
}

// RateLimitLogin makes the next sign-in answer with HTTP 429 and the given
// Retry-After header value (a decimal seconds count, or "" for none).
func (s *Server) RateLimitLogin(retryAfter string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loginHTTPStatus = http.StatusTooManyRequests
	s.loginRetryAfter = retryAfter
}

// SetConnections sets the patient IDs the account's connections list
// returns; the first one is the one a Source follows.
func (s *Server) SetConnections(patientIDs ...string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.patientIDs = patientIDs
}

// SetGraph sets the current measurement (nil for none) and the history the
// graph endpoint returns for the followed patient.
func (s *Server) SetGraph(current *Measurement, history []Measurement) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.current = current
	s.history = history
}

// RejectTokenAfter makes the token issued by the NEXT successful sign-in
// stop working after it has been used successfully n times across the
// connections and graph endpoints combined; a request using it after that
// gets HTTP 401. It does not affect a token already issued.
func (s *Server) RejectTokenAfter(n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.nextTokenLimit = n
}

// RateLimit makes the next graph request answer with HTTP 429 and the
// given Retry-After header value (a decimal seconds count, or "" for
// none).
func (s *Server) RateLimit(retryAfter string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.graphHTTPStatus = http.StatusTooManyRequests
	s.graphRetryAfter = retryAfter
}

// Fail makes the next graph request answer with the given raw HTTP status
// (e.g. 500), simulating a server-side failure.
func (s *Server) Fail(status int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.graphHTTPStatus = status
}

// SetMode switches the fake's runtime behaviour to one of "fresh" (every
// graph request answers with a new current reading timestamped now),
// "stale" (every graph request answers with the same reading, fixed
// staleReadingAge old, and no new one), or "reject" (every sign-in is
// refused as for a wrong password). It takes effect on the very next
// request, with no restart needed, and is the one control the standalone
// fake (cmd/llufake) exposes over HTTP at /mode; the Go test suite drives
// the fake directly through SetGraph, RejectCredentials and their
// siblings instead and never calls this. Entering "reject" also
// invalidates any session already signed in, so a caller already polling
// hits it on its very next authenticated request rather than only on its
// next fresh sign-in.
func (s *Server) SetMode(mode string) error {
	switch mode {
	case "fresh", "stale", "reject":
	default:
		return fmt.Errorf("llufake: unknown mode %q, want one of fresh, stale, reject", mode)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.mode = mode
	if mode == "reject" {
		s.validToken = ""
	}
	return nil
}

// Mode reports the fake's current runtime mode, or "" if SetMode has
// never been called.
func (s *Server) Mode() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.mode
}

// Requests returns every request the fake has received so far, in order.
func (s *Server) Requests() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Request, len(s.requests))
	copy(out, s.requests)
	return out
}

func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.requests = append(s.requests, Request{Method: r.Method, Path: r.URL.Path, Header: r.Header.Clone()})
	s.mu.Unlock()

	switch {
	case r.URL.Path == "/llu/auth/login":
		s.handleLogin(w, r)
	case r.URL.Path == "/llu/connections":
		s.handleConnections(w, r)
	case strings.HasPrefix(r.URL.Path, "/llu/connections/") && strings.HasSuffix(r.URL.Path, "/graph"):
		s.handleGraph(w, r)
	case r.URL.Path == "/mode":
		s.handleMode(w, r)
	default:
		http.NotFound(w, r)
	}
}

// handleMode implements the runtime control surface SetMode/Mode expose
// over HTTP for the standalone fake (cmd/llufake): GET reports the
// current mode as plain text, POST sets it from the "mode" query
// parameter or, failing that, the request body, answering 400 naming the
// problem if it names none of "fresh", "stale", or "reject". The Go test
// suite never reaches this path.
func (s *Server) handleMode(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		fmt.Fprintln(w, s.Mode())
	case http.MethodPost:
		mode := strings.TrimSpace(r.URL.Query().Get("mode"))
		if mode == "" {
			body, _ := io.ReadAll(r.Body)
			mode = strings.TrimSpace(string(body))
		}
		if err := s.SetMode(mode); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		fmt.Fprintln(w, s.Mode())
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.mode == "reject" {
		writeJSON(w, map[string]any{"status": 2, "data": map[string]any{}})
		return
	}

	if s.loginHTTPStatus != 0 {
		status := s.loginHTTPStatus
		if s.loginRetryAfter != "" {
			w.Header().Set("Retry-After", s.loginRetryAfter)
		}
		s.loginHTTPStatus = 0
		s.loginRetryAfter = ""
		w.WriteHeader(status)
		return
	}

	if s.loginJSONStatus == 2 || s.loginJSONStatus == 4 {
		status := s.loginJSONStatus
		s.loginJSONStatus = 0
		writeJSON(w, map[string]any{"status": status, "data": map[string]any{}})
		return
	}

	if s.redirectRegion != "" {
		region := s.redirectRegion
		s.redirectRegion = ""
		writeJSON(w, map[string]any{"status": 0, "data": map[string]any{"redirect": true, "region": region}})
		return
	}

	s.tokenSeq++
	s.validToken = fmt.Sprintf("fake-token-%d", s.tokenSeq)
	s.tokenUsesLeft = s.nextTokenLimit
	s.nextTokenLimit = -1

	writeJSON(w, map[string]any{
		"status": 0,
		"data": map[string]any{
			"user":       map[string]any{"id": s.userID},
			"authTicket": map[string]any{"token": s.validToken, "expires": 0},
		},
	})
}

func (s *Server) handleConnections(w http.ResponseWriter, r *http.Request) {
	if !s.checkAuth(w, r) {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	conns := make([]map[string]any, 0, len(s.patientIDs))
	for _, id := range s.patientIDs {
		conns = append(conns, map[string]any{"patientId": id})
	}
	writeJSON(w, map[string]any{"status": 0, "data": conns})
}

func (s *Server) handleGraph(w http.ResponseWriter, r *http.Request) {
	if !s.checkAuth(w, r) {
		return
	}

	s.mu.Lock()
	status := s.graphHTTPStatus
	retryAfter := s.graphRetryAfter
	s.graphHTTPStatus = 0
	s.graphRetryAfter = ""
	mode := s.mode
	current := s.current
	history := s.history
	s.mu.Unlock()

	if status != 0 {
		if retryAfter != "" {
			w.Header().Set("Retry-After", retryAfter)
		}
		w.WriteHeader(status)
		return
	}

	if mode == "fresh" || mode == "stale" {
		m := dynamicMeasurement(mode)
		current = &m
		history = nil
	}

	var connection map[string]any
	if current != nil {
		connection = map[string]any{"glucoseMeasurement": measurementJSON(*current)}
	} else {
		connection = map[string]any{"glucoseMeasurement": nil}
	}

	graphData := make([]map[string]any, 0, len(history))
	for _, m := range history {
		graphData = append(graphData, measurementJSON(m))
	}

	writeJSON(w, map[string]any{
		"status": 0,
		"data": map[string]any{
			"connection": connection,
			"graphData":  graphData,
		},
	})
}

// checkAuth validates the Authorization and Account-Id headers against the
// currently valid token, consuming one use of it. It writes an HTTP 401
// itself and returns false when the token is missing, wrong, or exhausted.
func (s *Server) checkAuth(w http.ResponseWriter, r *http.Request) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	wantAuth := "Bearer " + s.validToken
	wantAccountID := sha256Hex(s.userID)

	if s.validToken == "" || r.Header.Get("Authorization") != wantAuth || r.Header.Get("Account-Id") != wantAccountID {
		w.WriteHeader(http.StatusUnauthorized)
		return false
	}

	if s.tokenUsesLeft == 0 {
		w.WriteHeader(http.StatusUnauthorized)
		return false
	}
	if s.tokenUsesLeft > 0 {
		s.tokenUsesLeft--
	}
	return true
}

// dynamicMeasurement builds the one reading SetMode's "fresh" and "stale"
// modes serve: timestamped now for "fresh", or staleReadingAge in the
// past for "stale", so it is computed at request time rather than fixed
// once, and a poller therefore sees it consistently fresh or consistently
// stale for as long as the mode stays set.
func dynamicMeasurement(mode string) Measurement {
	t := time.Now().UTC()
	if mode == "stale" {
		t = t.Add(-staleReadingAge)
	}
	formatted := t.Format(dynamicReadingFormat)
	return Measurement{
		FactoryTimestamp: formatted,
		Timestamp:        formatted,
		ValueInMgPerDl:   dynamicReadingMgDl,
		TrendArrow:       3, // flat
	}
}

func measurementJSON(m Measurement) map[string]any {
	return map[string]any{
		"FactoryTimestamp": m.FactoryTimestamp,
		"Timestamp":        m.Timestamp,
		"ValueInMgPerDl":   m.ValueInMgPerDl,
		"TrendArrow":       m.TrendArrow,
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func sha256Hex(userID string) string {
	sum := sha256.Sum256([]byte(userID))
	return hex.EncodeToString(sum[:])
}
