package tailnode_test

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/nightscout"
	"github.com/yaanfpv/cgm-relay/internal/store"
	"github.com/yaanfpv/cgm-relay/internal/tailnode"
)

const host = "relay.example-tailnet.ts.net"

func statusMap(t *testing.T, s tailnode.Status) map[string]string {
	t.Helper()
	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	m := map[string]string{}
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal %s: %v", b, err)
	}
	return m
}

// TestStateMapping checks every backend situation maps to its state and to
// exactly the keys that state carries.
func TestStateMapping(t *testing.T) {
	cases := []struct {
		name string
		obs  tailnode.Observation
		want map[string]string
	}{
		{"needs login", tailnode.Observation{Backend: "NeedsLogin", LoginURL: "https://login.example.test/a/abc"},
			map[string]string{"ts_state": "needs-login", "ts_login_url": "https://login.example.test/a/abc"}},
		{"needs approval", tailnode.Observation{Backend: "NeedsMachineAuth", NodeIPv4: "100.64.0.7"},
			map[string]string{"ts_state": "needs-approval", "ts_approve_url": "https://login.tailscale.com/admin/machines/100.64.0.7"}},
		{"starting", tailnode.Observation{Backend: "Starting"},
			map[string]string{"ts_state": "starting"}},
		{"running, no cert domains, funnel url given", tailnode.Observation{Backend: "Running", FunnelURL: "https://login.example.test/f"},
			map[string]string{"ts_state": "needs-funnel", "ts_funnel_url": "https://login.example.test/f"}},
		{"running, cert domain, funnel not allowed", tailnode.Observation{Backend: "Running", CertDomains: []string{host}},
			map[string]string{"ts_state": "needs-funnel"}},
		{"running, allowed, listening, public not answered", tailnode.Observation{Backend: "Running", CertDomains: []string{host}, FunnelAllowed: true, Listening: true},
			map[string]string{"ts_state": "setting-up", "ts_public_host": host}},
		{"running, public answered", tailnode.Observation{Backend: "Running", CertDomains: []string{host}, FunnelAllowed: true, Listening: true, PublicAnswered: true},
			map[string]string{"ts_state": "running", "ts_public_host": host}},
		{"last error", tailnode.Observation{Backend: "Running", CertDomains: []string{host}, FunnelAllowed: true, Listening: true, PublicAnswered: true, LastErr: "boom"},
			map[string]string{"ts_state": "error", "ts_error": "boom"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := statusMap(t, tailnode.State(c.obs))
			for k, v := range c.want {
				if got[k] != v {
					t.Errorf("%s = %q, want %q (all: %v)", k, got[k], v, got)
				}
			}
			for k := range got {
				if _, ok := c.want[k]; !ok {
					t.Errorf("unexpected key %s = %q", k, got[k])
				}
			}
		})
	}
}

// TestStatePublicHostOnlyFromCertDomains checks no host is ever invented.
func TestStatePublicHostOnlyFromCertDomains(t *testing.T) {
	for _, o := range []tailnode.Observation{
		{Backend: "Running", FunnelAllowed: true, Listening: true, PublicAnswered: true},
		{Backend: "Running", FunnelAllowed: true, Listening: true},
		{Backend: "Running", NodeIPv4: "100.64.0.7"},
	} {
		if h := statusMap(t, tailnode.State(o))["ts_public_host"]; h != "" {
			t.Errorf("%+v: ts_public_host = %q, want none without CertDomains", o, h)
		}
	}
}

// TestStateNeverWaitsForever checks the two waiting states turn to errors at
// their limits and keep their state just under them.
func TestStateNeverWaitsForever(t *testing.T) {
	starting := tailnode.Observation{Backend: "Starting"}
	setting := tailnode.Observation{Backend: "Running", CertDomains: []string{host}, FunnelAllowed: true, Listening: true}
	cases := []struct {
		name  string
		obs   tailnode.Observation
		limit time.Duration
		state string
	}{
		{"starting", starting, tailnode.StartingLimit, "starting"},
		{"setting up", setting, tailnode.SettingUpLimit, "setting-up"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			under, at, past := c.obs, c.obs, c.obs
			under.InStateFor = c.limit - time.Nanosecond
			at.InStateFor = c.limit
			past.InStateFor = c.limit + time.Hour
			if got := statusMap(t, tailnode.State(under)); got["ts_state"] != c.state {
				t.Errorf("just under limit: ts_state = %q, want %q", got["ts_state"], c.state)
			}
			for _, o := range []tailnode.Observation{at, past} {
				got := statusMap(t, tailnode.State(o))
				if got["ts_state"] != "error" || got["ts_error"] == "" {
					t.Errorf("InStateFor %v: got %v, want error with ts_error", o.InStateFor, got)
				}
			}
		})
	}
}

// TestPublicHandlerAllowlist checks only the follower API paths reach the
// wrapped handler; everything else is a 404 that never reaches it.
func TestPublicHandlerAllowlist(t *testing.T) {
	allowed := []string{
		"/", "/api/v1/status.json", "/connect/abc123", "/api/v1/entries/sgv.json",
		"/api/v1/entries.json", "/api/v1/entries/current.json", "/api/v1/experiments/test",
		"/api/v1/treatments.json", "/api/v1/devicestatus.json", "/api/v1/profile",
	}
	refused := []string{
		"/admin", "/status", "/pairing", "/debug/pprof/", "/../etc/passwd", "/api/v2/entries",
	}
	var reached []string
	h := tailnode.PublicHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = append(reached, r.URL.Path)
		w.WriteHeader(http.StatusOK)
	}))
	serve := func(path string) (int, bool) {
		reached = nil
		req := httptest.NewRequest(http.MethodGet, "http://relay.example-tailnet.ts.net/", nil)
		req.URL.Path = path
		req.RequestURI = path
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code, len(reached) > 0
	}
	for _, p := range allowed {
		if code, hit := serve(p); code != http.StatusOK || !hit {
			t.Errorf("%s: code %d, reached next %v; want 200 and reached", p, code, hit)
		}
	}
	for _, p := range refused {
		if code, hit := serve(p); code != http.StatusNotFound || hit {
			t.Errorf("%s: code %d, reached next %v; want 404 and not reached", p, code, hit)
		}
	}
}

// TestPublicHandlerAllowsV2Properties checks the v2 properties route and its
// property-list forms reach the wrapped handler, and that deeper, longer or
// misspelt paths do not.
func TestPublicHandlerAllowsV2Properties(t *testing.T) {
	allowed := []string{
		"/api/v2/properties", "/api/v2/properties/iob,cob", "/api/v2/properties/notaproperty",
	}
	refused := []string{
		"/api/v2/properties/a/b", "/api/v2/propertiesX", "/api/v2/props",
	}
	var reached bool
	h := tailnode.PublicHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		w.WriteHeader(http.StatusOK)
	}))
	serve := func(path string) (int, bool) {
		reached = false
		req := httptest.NewRequest(http.MethodGet, "http://relay.example-tailnet.ts.net/", nil)
		req.URL.Path = path
		req.RequestURI = path
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code, reached
	}
	for _, p := range allowed {
		if code, hit := serve(p); code != http.StatusOK || !hit {
			t.Errorf("%s: code %d, reached next %v; want 200 and reached", p, code, hit)
		}
	}
	for _, p := range refused {
		if code, hit := serve(p); code != http.StatusNotFound || hit {
			t.Errorf("%s: code %d, reached next %v; want 404 and not reached", p, code, hit)
		}
	}
}

// TestLimitListener checks that with a cap of 2 a third Accept waits until a
// held connection closes.
func TestLimitListener(t *testing.T) {
	if tailnode.MaxPublicConns <= 0 {
		t.Fatalf("MaxPublicConns = %d, want > 0", tailnode.MaxPublicConns)
	}
	inner, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	l := tailnode.LimitListener(inner, 2)
	defer l.Close()

	var clients []net.Conn
	for i := 0; i < 3; i++ {
		c, err := net.Dial("tcp", l.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		clients = append(clients, c)
	}
	var held []net.Conn
	for i := 0; i < 2; i++ {
		c, err := l.Accept()
		if err != nil {
			t.Fatalf("accept %d: %v", i, err)
		}
		held = append(held, c)
	}
	third := make(chan error, 1)
	go func() {
		c, err := l.Accept()
		if err == nil {
			defer c.Close()
		}
		third <- err
	}()
	// The third client is already connected and queued, so a missing cap
	// would let this Accept return at once; this check can miss that only by
	// losing a scheduling race, never fail a correct listener.
	select {
	case err := <-third:
		t.Fatalf("third Accept returned (%v) while two connections were held", err)
	default:
	}
	held[0].Close()
	select {
	case err := <-third:
		if err != nil {
			t.Fatalf("third Accept after a close: %v", err)
		}
	case <-time.After(time.Minute): // hang ceiling only, not an expectation
		t.Fatal("third Accept still blocked after a held connection closed")
	}
	held[1].Close()
}

// noReadings is a ReadingRange with nothing stored; the status route reads
// no readings, so it is only here to build the real Nightscout handler.
type noReadings struct{}

func (noReadings) Range(context.Context, store.RangeQuery) ([]cgm.Reading, error) {
	return nil, nil
}

// TestPublicStatusChecksPresentedCredential checks that on the
// public listener's handler, wrapping the real Nightscout handler, status
// answers 401 with Nightscout's body to a presented wrong credential (token
// query, api-secret, Bearer), 200 with none, and 200 with the right one in
// each accepted form.
func TestPublicStatusChecksPresentedCredential(t *testing.T) {
	const token = "public-token"
	const wantBody = `{"status":401,"message":"Unauthorized","description":"Invalid/Missing"}`
	ns, err := nightscout.New(noReadings{}, token, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	h := tailnode.PublicHandler(ns)
	cases := []struct {
		name   string
		query  string
		header map[string]string
		want   int
	}{
		{"wrong token query", "?token=wrong", nil, 401},
		{"wrong api-secret", "", map[string]string{"api-secret": "wrong"}, 401},
		{"wrong bearer", "", map[string]string{"Authorization": "Bearer wrong"}, 401},
		{"no credential", "", nil, 200},
		{"right token query", "?token=" + token, nil, 200},
		{"right api-secret raw", "", map[string]string{"api-secret": token}, 200},
		{"right bearer", "", map[string]string{"Authorization": "Bearer " + token}, 200},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "http://relay.example-tailnet.ts.net/api/v1/status.json"+c.query, nil)
			for k, v := range c.header {
				req.Header.Set(k, v)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != c.want {
				t.Fatalf("status = %d, want %d (body: %s)", rec.Code, c.want, rec.Body.String())
			}
			if c.want == 401 {
				if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
					t.Errorf("Content-Type = %q, want application/json prefix", ct)
				}
				if got := strings.TrimSpace(rec.Body.String()); got != wantBody {
					t.Errorf("body = %s, want %s", got, wantBody)
				}
			}
		})
	}
}
