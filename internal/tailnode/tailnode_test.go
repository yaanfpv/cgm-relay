package tailnode_test

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"slices"
	"strings"
	"syscall"
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
// each accepted form, and judges a credential sent twice by every occurrence.
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
		lines  []string // header lines sent verbatim, repeats included
		want   int
	}{
		{"wrong token query", "?token=wrong", nil, nil, 401},
		{"wrong api-secret", "", map[string]string{"api-secret": "wrong"}, nil, 401},
		{"wrong bearer", "", map[string]string{"Authorization": "Bearer wrong"}, nil, 401},
		{"no credential", "", nil, nil, 200},
		{"right token query", "?token=" + token, nil, nil, 200},
		{"right api-secret raw", "", map[string]string{"api-secret": token}, nil, 200},
		{"right bearer", "", map[string]string{"Authorization": "Bearer " + token}, nil, 200},
		{"blank then wrong token query", "?token=&token=wrong", nil, nil, 401},
		{"blank then wrong api-secret", "", nil, []string{"Api-Secret: ", "Api-Secret: wrong"}, 401},
		{"blank then wrong bearer", "", nil, []string{"Authorization: ", "Authorization: Bearer wrong"}, 401},
		{"wrong then right token query", "?token=wrong&token=" + token, nil, nil, 200},
		{"wrong then right api-secret", "", nil, []string{"Api-Secret: wrong", "Api-Secret: " + token}, 200},
		{"wrong then right bearer", "", nil, []string{"Authorization: Bearer wrong", "Authorization: Bearer " + token}, 200},
		{"blank token query twice", "?token=&token=", nil, nil, 200},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "http://relay.example-tailnet.ts.net/api/v1/status.json"+c.query, nil)
			if len(c.lines) > 0 {
				// Parse the lines with Go's own request reader so a repeated
				// header arrives as separate lines, as it does on the wire.
				raw := "GET /api/v1/status.json" + c.query + " HTTP/1.1\r\nHost: " + host + "\r\n" + strings.Join(c.lines, "\r\n") + "\r\n\r\n"
				var err error
				if req, err = http.ReadRequest(bufio.NewReader(strings.NewReader(raw))); err != nil {
					t.Fatalf("ReadRequest: %v", err)
				}
			}
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

// The route-health tests below drive the pure parts of the public address's
// health: what State reports once a time and a verdict are known, and the
// Monitor that turns public tests into those verdicts and repairs. Each
// test runs on a fake clock and a fake probe, so none sleeps or touches a
// network. A fake only ever stands in for what the real node cannot give a
// test (a tailnet, Funnel, the public internet); the loopback tests further
// down run the real probe against local listeners.

var epoch = time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)

// stamp is how the engine writes the time epoch+d on the wire.
func stamp(d time.Duration) string { return epoch.Add(d).Format(time.RFC3339) }

func statusAny(t *testing.T, s tailnode.Status) map[string]any {
	t.Helper()
	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	m := map[string]any{}
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal %s: %v", b, err)
	}
	return m
}

func answeringObs() tailnode.Observation {
	return tailnode.Observation{Backend: "Running", CertDomains: []string{host}, FunnelAllowed: true, Listening: true, PublicAnswered: true}
}

var (
	routeClasses = []tailnode.ProbeClass{tailnode.ProbeRouteDropped, tailnode.ProbeRouteTLS, tailnode.ProbeRouteServerError}
	macClasses   = []tailnode.ProbeClass{tailnode.ProbeMacDNS, tailnode.ProbeMacNoRoute, tailnode.ProbeMacRefused, tailnode.ProbeMacTimeout}
	nodeClasses  = []tailnode.ProbeClass{tailnode.ProbeNodeOffline, tailnode.ProbeNodeHealth, tailnode.ProbeStatusRead}
)

func allFailureClasses() []tailnode.ProbeClass {
	var all []tailnode.ProbeClass
	all = append(all, routeClasses...)
	all = append(all, macClasses...)
	all = append(all, nodeClasses...)
	return append(all, tailnode.ProbeTailnetAddress)
}

// TestStateReadyCarriesTimeOfLastTest protects the "Ready, checked 15:42"
// line: a person reads when the address last answered from this one field.
// A state that drops the time, or writes it in another zone or shape, fails
// it. The existing mapping test cannot, because it never sets a time.
func TestStateReadyCarriesTimeOfLastTest(t *testing.T) {
	o := answeringObs()
	o.CheckedAt = epoch
	o.Now = epoch.Add(5 * time.Minute)
	got := statusAny(t, tailnode.State(o))
	if got["ts_state"] != "running" || got["ts_public_host"] != host {
		t.Fatalf("got %v, want running on %s", got, host)
	}
	if got["ts_checked_at"] != stamp(0) {
		t.Errorf("ts_checked_at = %v, want %s", got["ts_checked_at"], stamp(0))
	}
}

// TestStateReadyExpiresWithoutRecentTest protects the promise that Ready
// means the address answered lately: with the last successful test older
// than six minutes the state must not say running, whatever else the node
// reports. A state that trusts the old success forever (the behaviour today)
// fails it.
func TestStateReadyExpiresWithoutRecentTest(t *testing.T) {
	for _, age := range []time.Duration{0, 2 * time.Minute, 5*time.Minute + 59*time.Second} {
		o := answeringObs()
		o.CheckedAt, o.Now = epoch, epoch.Add(age)
		if got := statusAny(t, tailnode.State(o))["ts_state"]; got != "running" {
			t.Errorf("last test %v ago: ts_state = %v, want running", age, got)
		}
	}
	for _, age := range []time.Duration{6*time.Minute + time.Second, 7 * time.Minute, time.Hour} {
		o := answeringObs()
		o.CheckedAt, o.Now = epoch, epoch.Add(age)
		if got := statusAny(t, tailnode.State(o))["ts_state"]; got == "running" {
			t.Errorf("last test %v ago: ts_state = running, want anything else", age)
		}
	}
}

// TestStateNotAnsweringAndWaitingForInternet protects the two new verdicts
// on the wire: not answering carries the time of the first failure and the
// host, waiting for the internet carries the host, neither is the generic
// error state, and waiting wins when both are set because a Mac that is
// offline says nothing about the route.
func TestStateNotAnsweringAndWaitingForInternet(t *testing.T) {
	na := answeringObs()
	na.Now = epoch.Add(10 * time.Minute)
	na.CheckedAt = epoch.Add(-time.Hour)
	na.NotAnsweringSince = epoch.Add(time.Minute)
	got := statusAny(t, tailnode.State(na))
	if got["ts_state"] != "not-answering" || got["ts_not_answering_since"] != stamp(time.Minute) || got["ts_public_host"] != host {
		t.Errorf("not answering: got %v", got)
	}
	if _, ok := got["ts_error"]; ok {
		t.Errorf("not answering carries ts_error: %v", got)
	}

	wait := answeringObs()
	wait.Now = epoch
	wait.WaitingForInternet = true
	got = statusAny(t, tailnode.State(wait))
	if got["ts_state"] != "waiting-for-internet" || got["ts_public_host"] != host {
		t.Errorf("waiting: got %v", got)
	}
	if _, ok := got["ts_error"]; ok {
		t.Errorf("waiting carries ts_error: %v", got)
	}

	both := na
	both.WaitingForInternet = true
	if got := statusAny(t, tailnode.State(both))["ts_state"]; got != "waiting-for-internet" {
		t.Errorf("both set: ts_state = %v, want waiting-for-internet", got)
	}
}

// TestStateCarriesCounts protects the wire for diagnostics: the counts the
// engine keeps reach the status as whole numbers under one key, and a state
// without counts has no such key.
func TestStateCarriesCounts(t *testing.T) {
	o := answeringObs()
	o.Counts = map[string]int{"ingress_denied": 3, "handshake": 1}
	got := statusAny(t, tailnode.State(o))
	counts, ok := got["ts_counts"].(map[string]any)
	if !ok || counts["ingress_denied"] != float64(3) || counts["handshake"] != float64(1) {
		t.Errorf("ts_counts = %v, want ingress_denied 3 and handshake 1", got["ts_counts"])
	}
	if _, ok := statusAny(t, tailnode.State(answeringObs()))["ts_counts"]; ok {
		t.Error("a state with no counts carries ts_counts")
	}
}

type fakeClock struct{ now time.Time }

type repairLog struct {
	clock    *fakeClock
	kinds    []string
	restarts []time.Time
}

func (r *repairLog) ReopenListener(context.Context) error {
	r.kinds = append(r.kinds, "reopen")
	return nil
}

func (r *repairLog) RestartNode(context.Context) error {
	r.kinds = append(r.kinds, "restart")
	r.restarts = append(r.restarts, r.clock.now)
	return nil
}

// rig is a Monitor on a fake clock whose public test and node check answer
// whatever the test sets.
type rig struct {
	t      *testing.T
	clock  *fakeClock
	rep    *repairLog
	probe  tailnode.ProbeClass
	node   tailnode.ProbeClass
	probes int
	m      *tailnode.Monitor
}

func newRig(t *testing.T) *rig {
	r := &rig{t: t, clock: &fakeClock{now: epoch}, probe: tailnode.ProbeOK, node: tailnode.ProbeOK}
	r.rep = &repairLog{clock: r.clock}
	r.m = tailnode.NewMonitor(tailnode.MonitorOptions{
		Now: func() time.Time { return r.clock.now },
		Probe: func(_ context.Context, h string) tailnode.ProbeClass {
			r.probes++
			if h != host {
				t.Errorf("probe asked about %q, want %q", h, host)
			}
			return r.probe
		},
		Node:   func(context.Context) tailnode.ProbeClass { return r.node },
		Repair: r.rep,
	})
	return r
}

func (r *rig) at(d time.Duration) { r.clock.now = epoch.Add(d) }

// step runs one test at epoch+d whose public result is class.
func (r *rig) step(d time.Duration, class tailnode.ProbeClass) time.Duration {
	r.at(d)
	r.probe = class
	return r.m.Step(context.Background(), host)
}

func (r *rig) status() map[string]any {
	r.t.Helper()
	return statusAny(r.t, tailnode.State(r.m.Apply(answeringObs())))
}

func (r *rig) state() string {
	r.t.Helper()
	s, _ := r.status()["ts_state"].(string)
	return s
}

// ready brings the rig to a healthy address whose last test was ten seconds
// before epoch.
func (r *rig) ready() {
	r.t.Helper()
	r.step(-10*time.Second, tailnode.ProbeOK)
	if got := r.state(); got != "running" {
		r.t.Fatalf("after a successful test: ts_state = %q, want running", got)
	}
}

// notAnswering fails the route three times over four minutes, from epoch.
func (r *rig) notAnswering() {
	r.t.Helper()
	for _, d := range []time.Duration{0, 100 * time.Second, 240 * time.Second} {
		r.step(d, tailnode.ProbeRouteDropped)
	}
	if got := r.state(); got != "not-answering" {
		r.t.Fatalf("after three failures over four minutes: ts_state = %q, want not-answering", got)
	}
}

// TestMonitorReadyIsEarnedAndKeptFresh protects Ready itself: no success yet
// is not Ready even when the node believes it answered, a success is Ready
// with its time, a later success moves the time, and a success that is
// older than six minutes stops being Ready with no other event. A monitor
// that starts Ready, or never lets a success go stale, fails it.
func TestMonitorReadyIsEarnedAndKeptFresh(t *testing.T) {
	r := newRig(t)
	if got := r.state(); got == "running" {
		t.Fatalf("before any test: ts_state = running")
	}
	if d := r.step(0, tailnode.ProbeOK); d != 2*time.Minute {
		t.Errorf("next test after a success in %v, want 2m0s", d)
	}
	if st := r.status(); st["ts_state"] != "running" || st["ts_checked_at"] != stamp(0) {
		t.Fatalf("after a success: %v", st)
	}
	r.step(2*time.Minute, tailnode.ProbeOK)
	if st := r.status(); st["ts_checked_at"] != stamp(2*time.Minute) {
		t.Errorf("after a second success: ts_checked_at = %v, want %s", st["ts_checked_at"], stamp(2*time.Minute))
	}
	r.at(2*time.Minute + 5*time.Minute + 59*time.Second)
	if got := r.state(); got != "running" {
		t.Errorf("just under six minutes after the last success: %q, want running", got)
	}
	r.at(2*time.Minute + 6*time.Minute + time.Second)
	if got := r.state(); got == "running" {
		t.Error("over six minutes after the last success, with no test since: still running")
	}
}

// TestMonitorNotAnsweringNeedsThreeFailuresOverFourMinutes protects against
// both wrong directions: Ready after three real route failures, and a
// not-answering report on a blip. It runs every route failure class, since
// a drop during TLS, a TLS failure and a 5xx are separate members of the
// class. The time reported is the first failure of the current run.
func TestMonitorNotAnsweringNeedsThreeFailuresOverFourMinutes(t *testing.T) {
	cases := []struct {
		name    string
		offsets []time.Duration
		na      bool
	}{
		{"one failure", []time.Duration{0}, false},
		{"two failures", []time.Duration{0, 30 * time.Second}, false},
		{"three failures inside two minutes", []time.Duration{0, 30 * time.Second, 90 * time.Second}, false},
		{"three failures just under four minutes", []time.Duration{0, 100 * time.Second, 239 * time.Second}, false},
		{"three failures spanning four minutes", []time.Duration{0, 100 * time.Second, 240 * time.Second}, true},
		{"five failures, the last past four minutes", []time.Duration{0, 10 * time.Second, 20 * time.Second, 30 * time.Second, 250 * time.Second}, true},
	}
	for _, class := range routeClasses {
		for _, c := range cases {
			t.Run(class.String()+"/"+c.name, func(t *testing.T) {
				r := newRig(t)
				r.ready()
				for i, d := range c.offsets {
					r.step(d, class)
					last := i == len(c.offsets)-1
					want := "running"
					if last && c.na {
						want = "not-answering"
					}
					if got := r.state(); got != want {
						t.Fatalf("after failure %d at %v: ts_state = %q, want %q", i+1, d, got, want)
					}
				}
				if c.na {
					if got := r.status()["ts_not_answering_since"]; got != stamp(0) {
						t.Errorf("ts_not_answering_since = %v, want %s", got, stamp(0))
					}
				}
			})
		}
	}
}

// TestMonitorSuccessEndsTheRun protects "the first successful test returns
// Ready" and that a success starts the count again: two failures, a success
// and two more failures are not a run of three, and the run that does
// complete is timed from its own first failure.
func TestMonitorSuccessEndsTheRun(t *testing.T) {
	r := newRig(t)
	r.ready()
	r.step(0, tailnode.ProbeRouteTLS)
	r.step(100*time.Second, tailnode.ProbeRouteTLS)
	r.step(150*time.Second, tailnode.ProbeOK)
	r.step(200*time.Second, tailnode.ProbeRouteTLS)
	r.step(300*time.Second, tailnode.ProbeRouteTLS)
	if got := r.state(); got != "running" {
		t.Fatalf("two failures after a success: ts_state = %q, want running", got)
	}
	r.step(450*time.Second, tailnode.ProbeRouteTLS)
	st := r.status()
	if st["ts_state"] != "not-answering" || st["ts_not_answering_since"] != stamp(200*time.Second) {
		t.Fatalf("third failure of the new run: %v, want not-answering since %s", st, stamp(200*time.Second))
	}
	r.step(500*time.Second, tailnode.ProbeOK)
	st = r.status()
	if st["ts_state"] != "running" || st["ts_checked_at"] != stamp(500*time.Second) {
		t.Errorf("after a success: %v, want running checked at %s", st, stamp(500*time.Second))
	}
	if _, ok := st["ts_not_answering_since"]; ok {
		t.Errorf("running still carries ts_not_answering_since: %v", st)
	}
}

// TestMonitorBackoffAfterFailure protects the test cadence: 30 seconds after
// the first failure, 60 after the second, never more than five minutes, and
// back to two minutes after a success. A monitor that keeps testing every
// two minutes through a failure (slow to notice) or hammers the address
// (never backs off) fails it.
func TestMonitorBackoffAfterFailure(t *testing.T) {
	r := newRig(t)
	now := time.Duration(0)
	var delays []time.Duration
	for i := 0; i < 20; i++ {
		d := r.step(now, tailnode.ProbeRouteDropped)
		delays = append(delays, d)
		now += d
	}
	if delays[0] != 30*time.Second || delays[1] != 60*time.Second {
		t.Errorf("first delays %v, %v, want 30s then 1m0s", delays[0], delays[1])
	}
	for i, d := range delays {
		if d <= 0 || d > 5*time.Minute {
			t.Errorf("delay %d = %v, want within (0, 5m]", i+1, d)
		}
		if i > 0 && d < delays[i-1] {
			t.Errorf("delay %d = %v is shorter than the one before, %v", i+1, d, delays[i-1])
		}
	}
	if d := r.step(now, tailnode.ProbeOK); d != 2*time.Minute {
		t.Errorf("delay after a success = %v, want 2m0s", d)
	}
}

// TestMonitorMacSideFailureWaitsAndNeverRepairs protects the line between
// the Mac's network and the address: a failure before any connection
// (DNS, no route, refused, timed out), or a node that is offline, unhealthy
// or cannot be read, is "waiting for the internet", never "not answering",
// and nothing is reopened or restarted for it however long it lasts. A
// restart for a dead Wi-Fi link would only churn the node. The node-side
// members are the status-read-failed case too, so a failed read can never
// leave the old state standing.
func TestMonitorMacSideFailureWaitsAndNeverRepairs(t *testing.T) {
	// A node-side class explains a public test that failed, so each is paired
	// with a failing probe: a route failure and a failure on the Mac's side.
	macSide := func(t *testing.T, r *rig, class, probe tailnode.ProbeClass, d time.Duration) {
		t.Helper()
		r.node, r.probe = tailnode.ProbeOK, probe
		if class.NodeSide() {
			r.node = class
		} else {
			r.probe = class
		}
		r.at(d)
		r.m.Step(context.Background(), host)
	}
	type pair struct{ class, probe tailnode.ProbeClass }
	var pairs []pair
	for _, class := range macClasses {
		pairs = append(pairs, pair{class, tailnode.ProbeOK})
	}
	for _, class := range nodeClasses {
		// A health warning explains nothing about a route failure, so it is
		// paired with a failure on the Mac's side only.
		if class != tailnode.ProbeNodeHealth {
			pairs = append(pairs, pair{class, tailnode.ProbeRouteDropped})
		}
		pairs = append(pairs, pair{class, tailnode.ProbeMacDNS})
	}
	for _, p := range pairs {
		t.Run(p.class.String()+"/"+p.probe.String(), func(t *testing.T) {
			r := newRig(t)
			r.ready()
			for i := 0; i < 10; i++ {
				macSide(t, r, p.class, p.probe, time.Duration(i)*5*time.Minute)
				if got := r.state(); got != "waiting-for-internet" {
					t.Fatalf("step %d: ts_state = %q, want waiting-for-internet", i+1, got)
				}
			}
			if len(r.rep.kinds) != 0 {
				t.Errorf("repairs for a failure on the Mac's side: %v", r.rep.kinds)
			}
			r.node = tailnode.ProbeOK
			r.step(time.Hour, tailnode.ProbeOK)
			if got := r.state(); got != "running" {
				t.Errorf("after a success: ts_state = %q, want running", got)
			}
		})
	}
	// A public test that succeeds is Ready whatever the node reports.
	for _, class := range nodeClasses {
		t.Run("answered while the node reports "+class.String(), func(t *testing.T) {
			r := newRig(t)
			r.ready()
			r.node = class
			r.step(0, tailnode.ProbeOK)
			if got := r.state(); got != "running" {
				t.Errorf("ts_state = %q, want running", got)
			}
			if got := r.m.Counts()[class.String()]; got != 0 {
				t.Errorf("count of %s = %d after an answered test, want 0", class, got)
			}
			if len(r.rep.kinds) != 0 {
				t.Errorf("repairs after an answered test: %v", r.rep.kinds)
			}
		})
	}
	t.Run("while not answering", func(t *testing.T) {
		r := newRig(t)
		r.ready()
		r.notAnswering()
		before := len(r.rep.kinds)
		for i, p := range pairs {
			macSide(t, r, p.class, p.probe, 5*time.Minute+time.Duration(i)*5*time.Minute)
			if got := r.state(); got != "waiting-for-internet" {
				t.Errorf("%v with %v: ts_state = %q, want waiting-for-internet", p.class, p.probe, got)
			}
		}
		if len(r.rep.kinds) != before {
			t.Errorf("repairs ran while the Mac's network was down: %v", r.rep.kinds[before:])
		}
	})
}

// TestMonitorHealthWarningNeverHidesARouteFailure protects the repair of a
// real drop on a node that carries a health warning which never clears: the
// route failures count toward not answering and the ladder runs as usual,
// and the warning is only counted. A warning that turned the state into
// waiting would leave the address dead with nothing repairing it.
func TestMonitorHealthWarningNeverHidesARouteFailure(t *testing.T) {
	r := newRig(t)
	r.ready()
	r.node = tailnode.ProbeNodeHealth
	for _, d := range []time.Duration{0, 100 * time.Second, 240 * time.Second} {
		r.step(d, tailnode.ProbeRouteDropped)
	}
	if got := r.state(); got != "not-answering" {
		t.Fatalf("ts_state = %q, want not-answering", got)
	}
	r.step(300*time.Second, tailnode.ProbeRouteDropped)
	r.step(360*time.Second, tailnode.ProbeRouteDropped)
	if want := []string{"reopen", "reopen", "restart"}; !slices.Equal(r.rep.kinds, want) {
		t.Errorf("repairs %v, want %v", r.rep.kinds, want)
	}
	if got := r.m.Counts()["node_unhealthy"]; got != 5 {
		t.Errorf("node_unhealthy count = %d, want 5", got)
	}
}

// TestMonitorTailnetAddressCountsAsNeither protects against a name that
// resolves inside the tailnet passing for the public one: it never renews
// Ready, never lifts a not-answering report, and it neither adds to nor
// breaks a run of failures.
func TestMonitorTailnetAddressCountsAsNeither(t *testing.T) {
	t.Run("does not renew ready", func(t *testing.T) {
		r := newRig(t)
		r.step(0, tailnode.ProbeOK)
		r.step(time.Minute, tailnode.ProbeTailnetAddress)
		if got := r.status()["ts_checked_at"]; got != stamp(0) {
			t.Errorf("ts_checked_at = %v after a tailnet answer, want %s", got, stamp(0))
		}
	})
	t.Run("does not lift not answering", func(t *testing.T) {
		r := newRig(t)
		r.ready()
		r.notAnswering()
		r.step(5*time.Minute, tailnode.ProbeTailnetAddress)
		if got := r.state(); got != "not-answering" {
			t.Errorf("ts_state = %q after a tailnet answer, want not-answering", got)
		}
	})
	t.Run("does not break a run", func(t *testing.T) {
		r := newRig(t)
		r.ready()
		r.step(0, tailnode.ProbeRouteDropped)
		r.step(100*time.Second, tailnode.ProbeRouteDropped)
		r.step(150*time.Second, tailnode.ProbeTailnetAddress)
		r.step(240*time.Second, tailnode.ProbeRouteDropped)
		if got := r.state(); got != "not-answering" {
			t.Errorf("ts_state = %q, want not-answering: the tailnet answer between failures must not reset the run", got)
		}
	})
	t.Run("is not a failure", func(t *testing.T) {
		r := newRig(t)
		r.ready()
		r.step(0, tailnode.ProbeRouteDropped)
		for _, d := range []time.Duration{100 * time.Second, 200 * time.Second, 300 * time.Second} {
			r.step(d, tailnode.ProbeTailnetAddress)
		}
		if got := r.state(); got != "running" {
			t.Errorf("one failure and three tailnet answers: ts_state = %q, want running", got)
		}
	})
}

// TestMonitorRepairLadder protects the order of repairs: none for one or two
// failures, a reopen of the public listener on becoming not answering, a
// second reopen at the next failed test, and only then a full restart of the
// node. A ladder that restarts first, or repairs on a blip, fails it.
func TestMonitorRepairLadder(t *testing.T) {
	r := newRig(t)
	r.ready()
	r.step(0, tailnode.ProbeRouteServerError)
	r.step(100*time.Second, tailnode.ProbeRouteServerError)
	if len(r.rep.kinds) != 0 {
		t.Fatalf("repairs after two failures: %v", r.rep.kinds)
	}
	r.step(240*time.Second, tailnode.ProbeRouteServerError)
	want := []string{"reopen"}
	if !slices.Equal(r.rep.kinds, want) {
		t.Fatalf("on becoming not answering: repairs %v, want %v", r.rep.kinds, want)
	}
	r.step(300*time.Second, tailnode.ProbeRouteServerError)
	want = append(want, "reopen")
	if !slices.Equal(r.rep.kinds, want) {
		t.Fatalf("next failed test: repairs %v, want %v", r.rep.kinds, want)
	}
	r.step(360*time.Second, tailnode.ProbeRouteServerError)
	want = append(want, "restart")
	if !slices.Equal(r.rep.kinds, want) {
		t.Fatalf("after two reopens: repairs %v, want %v", r.rep.kinds, want)
	}
}

// TestMonitorRestartCaps protects the node from a restart loop: over three
// hours of an address that never answers, restarts are at least five
// minutes apart, never more than three in any hour, the state stays not
// answering, tests keep coming at least every five minutes, and the cap lifts
// with the hour. The first success after all of it is Ready again.
func TestMonitorRestartCaps(t *testing.T) {
	r := newRig(t)
	r.ready()
	r.at(0)
	r.probe = tailnode.ProbeRouteDropped
	end := epoch.Add(3 * time.Hour)
	var probesAtTwoHours int
	for r.clock.now.Before(end) {
		if probesAtTwoHours == 0 && !r.clock.now.Before(epoch.Add(2*time.Hour)) {
			probesAtTwoHours = r.probes
		}
		d := r.m.Step(context.Background(), host)
		if d <= 0 || d > 5*time.Minute {
			t.Fatalf("at %v the next test is in %v, want within (0, 5m]", r.clock.now.Sub(epoch), d)
		}
		r.clock.now = r.clock.now.Add(d)
	}
	rs := r.rep.restarts
	if len(rs) == 0 || !rs[0].Before(epoch.Add(time.Hour)) {
		t.Fatalf("restarts %v: want at least one in the first hour", rs)
	}
	for i := 1; i < len(rs); i++ {
		if rs[i].Sub(rs[i-1]) < 5*time.Minute {
			t.Errorf("restarts %d and %d are %v apart, want at least 5m", i, i+1, rs[i].Sub(rs[i-1]))
		}
		if i >= 3 && rs[i].Sub(rs[i-3]) < time.Hour {
			t.Errorf("restarts %d to %d span %v, want at least an hour for four", i-2, i+1, rs[i].Sub(rs[i-3]))
		}
	}
	if last := rs[len(rs)-1]; !last.After(epoch.Add(time.Hour)) {
		t.Errorf("no restart after the first hour (last at %v): the cap must lift", last.Sub(epoch))
	}
	if got := r.state(); got != "not-answering" {
		t.Errorf("after three hours of failures: ts_state = %q, want not-answering", got)
	}
	if n := r.probes - probesAtTwoHours; n < 12 {
		t.Errorf("only %d tests in the last hour, want at least 12", n)
	}
	r.step(3*time.Hour+time.Minute, tailnode.ProbeOK)
	if got := r.state(); got != "running" {
		t.Errorf("after a success: ts_state = %q, want running", got)
	}
}

// TestMonitorTryAgain protects the button: it tests at once, ignoring the
// wait, and on a failed test takes the next repair step, but never past the
// restart caps; a success returns Ready with no repair.
func TestMonitorTryAgain(t *testing.T) {
	ctx := context.Background()
	t.Run("repairs one step per press and keeps the caps", func(t *testing.T) {
		r := newRig(t)
		r.ready()
		r.notAnswering()
		if !slices.Equal(r.rep.kinds, []string{"reopen"}) {
			t.Fatalf("repairs on becoming not answering: %v", r.rep.kinds)
		}
		before := r.probes
		r.at(250 * time.Second)
		r.probe = tailnode.ProbeRouteDropped
		if d := r.m.TryAgain(ctx, host); d <= 0 || d > 5*time.Minute {
			t.Errorf("next test in %v, want within (0, 5m]", d)
		}
		if r.probes != before+1 {
			t.Errorf("Try Again ran %d tests, want 1", r.probes-before)
		}
		if !slices.Equal(r.rep.kinds, []string{"reopen", "reopen"}) {
			t.Fatalf("after one press: repairs %v, want a second reopen", r.rep.kinds)
		}
		r.at(251 * time.Second)
		r.m.TryAgain(ctx, host)
		if !slices.Equal(r.rep.kinds, []string{"reopen", "reopen", "restart"}) {
			t.Fatalf("after two presses: repairs %v, want a restart", r.rep.kinds)
		}
		r.at(252 * time.Second)
		r.m.TryAgain(ctx, host)
		if len(r.rep.restarts) != 1 {
			t.Errorf("%d restarts a second apart, want the five-minute cap to hold at 1", len(r.rep.restarts))
		}
		if got := r.state(); got != "not-answering" {
			t.Errorf("ts_state = %q, want not-answering", got)
		}
		n := len(r.rep.kinds)
		r.at(253 * time.Second)
		r.probe = tailnode.ProbeOK
		r.m.TryAgain(ctx, host)
		if got := r.status(); got["ts_state"] != "running" || got["ts_checked_at"] != stamp(253*time.Second) {
			t.Errorf("after a successful press: %v", got)
		}
		if len(r.rep.kinds) != n {
			t.Errorf("a successful press repaired: %v", r.rep.kinds[n:])
		}
	})
	t.Run("on a healthy address does nothing but test", func(t *testing.T) {
		r := newRig(t)
		r.ready()
		r.at(time.Second)
		r.probe = tailnode.ProbeOK
		r.m.TryAgain(ctx, host)
		if len(r.rep.kinds) != 0 || r.state() != "running" {
			t.Errorf("repairs %v, state %q", r.rep.kinds, r.state())
		}
	})
	t.Run("does not repair the Mac's network", func(t *testing.T) {
		r := newRig(t)
		r.ready()
		r.at(time.Second)
		r.probe = tailnode.ProbeMacDNS
		r.m.TryAgain(ctx, host)
		if len(r.rep.kinds) != 0 || r.state() != "waiting-for-internet" {
			t.Errorf("repairs %v, state %q", r.rep.kinds, r.state())
		}
	})
}

// TestMonitorCountsEachFailureClass protects diagnostics: every failure
// class has its own count, named distinctly, so a pattern (all TLS, all
// refused) can be read off a report.
func TestMonitorCountsEachFailureClass(t *testing.T) {
	seen := map[string]tailnode.ProbeClass{}
	for _, class := range allFailureClasses() {
		key := class.String()
		if key == "" {
			t.Fatalf("class %d has no name", class)
		}
		if other, dup := seen[key]; dup {
			t.Fatalf("classes %d and %d share the name %q", class, other, key)
		}
		seen[key] = class

		r := newRig(t)
		r.ready()
		for i := 1; i <= 2; i++ {
			r.node, r.probe = tailnode.ProbeOK, tailnode.ProbeOK
			if class.NodeSide() {
				// Only a failed public test is explained by the node.
				r.node, r.probe = class, tailnode.ProbeRouteDropped
			} else {
				r.probe = class
			}
			r.at(time.Duration(i) * time.Second)
			r.m.Step(context.Background(), host)
			if got := r.m.Counts()[key]; got != i {
				t.Errorf("%s: count after %d = %d", key, i, got)
			}
		}
	}
}

// TestMonitorCountsLogLines protects the two Tailscale log counts, and the
// rule that only a count survives: the line, its address and its peer name
// are dropped, and a line of neither kind adds nothing, not even a new key.
func TestMonitorCountsLogLines(t *testing.T) {
	r := newRig(t)
	allowed := map[string]bool{"ingress_denied": true, "handshake": true}
	for _, c := range allFailureClasses() {
		allowed[c.String()] = true
	}
	r.m.ObserveLog("ingress: denied; no ingress cap from 203.0.113.9:4444")
	r.m.ObserveLog("peer(abcd…wxyz) - Handshake did not complete after 5 seconds, retrying (try 2)")
	r.m.ObserveLog("ingress: denied; no ingress cap from 203.0.113.10:5555")
	for i := 0; i < 5000; i++ {
		r.m.ObserveLog(fmt.Sprintf("magicsock: derp-%d connected; connGen=%d to 198.51.100.%d:443", i, i, i%250))
	}
	got := r.m.Counts()
	if got["ingress_denied"] != 2 || got["handshake"] != 1 {
		t.Errorf("counts %v, want ingress_denied 2 and handshake 1", got)
	}
	for k := range got {
		if !allowed[k] {
			t.Errorf("unexpected count key %q", k)
		}
	}
	b, _ := json.Marshal(got)
	for _, leak := range []string{"203.0.113", "198.51.100", "abcd", "magicsock", host} {
		if strings.Contains(string(b), leak) {
			t.Errorf("counts %s contain %q", b, leak)
		}
	}
}

// TestMonitorCountsAreBounded protects the engine's memory and the report's
// size: a count stops at MaxCount instead of growing without end.
func TestMonitorCountsAreBounded(t *testing.T) {
	if tailnode.MaxCount < 1 || tailnode.MaxCount > 1_000_000 {
		t.Fatalf("MaxCount = %d, want between 1 and 1000000", tailnode.MaxCount)
	}
	r := newRig(t)
	for i := 0; i < tailnode.MaxCount+10; i++ {
		r.m.ObserveLog("ingress: denied; no ingress cap from 203.0.113.9:4444")
	}
	if got := r.m.Counts()["ingress_denied"]; got != tailnode.MaxCount {
		t.Errorf("ingress_denied = %d after %d lines, want it held at %d", got, tailnode.MaxCount+10, tailnode.MaxCount)
	}
}

// TestMonitorStatusCarriesCounts protects the link from the monitor to the
// wire: what the monitor counted is what the state reports.
func TestMonitorStatusCarriesCounts(t *testing.T) {
	r := newRig(t)
	r.ready()
	r.m.ObserveLog("ingress: denied; no ingress cap from 203.0.113.9:4444")
	counts, _ := r.status()["ts_counts"].(map[string]any)
	if counts["ingress_denied"] != float64(1) {
		t.Errorf("ts_counts = %v, want ingress_denied 1", r.status()["ts_counts"])
	}
}

type deadlineErr struct{}

func (deadlineErr) Error() string   { return "i/o timeout" }
func (deadlineErr) Timeout() bool   { return true }
func (deadlineErr) Temporary() bool { return true }

// TestClassifyProbe protects the line the repair rules depend on, using the
// error values net/http produces: only a failure after a connection was
// made is the route's. A DNS failure, no route, a refused connection or a
// connection that timed out before it was made would otherwise be read as an
// address that stopped answering, and the node restarted for a dead Wi-Fi
// link.
func TestClassifyProbe(t *testing.T) {
	urlErr := func(err error) error { return &url.Error{Op: "Get", URL: "https://" + host, Err: err} }
	dial := func(err error) error { return urlErr(&net.OpError{Op: "dial", Net: "tcp", Err: err}) }
	cases := []struct {
		name   string
		status int
		err    error
		want   tailnode.ProbeClass
	}{
		{"answered", 200, nil, tailnode.ProbeOK},
		{"server error 500", 500, nil, tailnode.ProbeRouteServerError},
		{"bad gateway", 502, nil, tailnode.ProbeRouteServerError},
		{"unavailable", 503, nil, tailnode.ProbeRouteServerError},
		{"dropped after connecting", 0, urlErr(io.EOF), tailnode.ProbeRouteDropped},
		{"reset after connecting", 0, urlErr(&net.OpError{Op: "read", Net: "tcp", Err: syscall.ECONNRESET}), tailnode.ProbeRouteDropped},
		{"tls handshake timeout", 0, urlErr(errors.New("net/http: TLS handshake timeout")), tailnode.ProbeRouteDropped},
		{"certificate not trusted", 0, urlErr(x509.UnknownAuthorityError{}), tailnode.ProbeRouteTLS},
		{"certificate not trusted, as the client reports it", 0, urlErr(&tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}), tailnode.ProbeRouteTLS},
		{"not a tls server", 0, urlErr(tls.RecordHeaderError{Msg: "first record does not look like a TLS handshake"}), tailnode.ProbeRouteTLS},
		{"name not found", 0, dial(&net.DNSError{Err: "no such host", Name: host, IsNotFound: true}), tailnode.ProbeMacDNS},
		{"resolver unreachable", 0, urlErr(&net.OpError{Op: "dial", Net: "udp", Err: &net.DNSError{Err: "server misbehaving", Name: host, IsTemporary: true}}), tailnode.ProbeMacDNS},
		{"connection refused", 0, dial(syscall.ECONNREFUSED), tailnode.ProbeMacRefused},
		{"host unreachable", 0, dial(syscall.EHOSTUNREACH), tailnode.ProbeMacNoRoute},
		{"network unreachable", 0, dial(syscall.ENETUNREACH), tailnode.ProbeMacNoRoute},
		{"connect timed out", 0, dial(deadlineErr{}), tailnode.ProbeMacTimeout},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := tailnode.ClassifyProbe(c.status, c.err); got != c.want {
				t.Errorf("ClassifyProbe(%d, %v) = %v, want %v", c.status, c.err, got, c.want)
			}
		})
	}
	for _, c := range []tailnode.ProbeClass{tailnode.ProbeRouteDropped, tailnode.ProbeRouteTLS, tailnode.ProbeRouteServerError} {
		if !c.RouteFailure() || c.MacSide() || c.NodeSide() {
			t.Errorf("%v: RouteFailure %v, MacSide %v, NodeSide %v", c, c.RouteFailure(), c.MacSide(), c.NodeSide())
		}
	}
	for _, c := range []tailnode.ProbeClass{tailnode.ProbeMacDNS, tailnode.ProbeMacNoRoute, tailnode.ProbeMacRefused, tailnode.ProbeMacTimeout} {
		if c.RouteFailure() || !c.MacSide() {
			t.Errorf("%v: RouteFailure %v, MacSide %v", c, c.RouteFailure(), c.MacSide())
		}
	}
	for _, c := range []tailnode.ProbeClass{tailnode.ProbeOK, tailnode.ProbeTailnetAddress} {
		if c.RouteFailure() || c.MacSide() || c.NodeSide() {
			t.Errorf("%v counts as a failure", c)
		}
	}
}

// TestIsTailnetAddress protects the edge of 100.64.0.0/10: the first and
// last address of the block are tailnet addresses, the ones either side and
// private ranges are not.
func TestIsTailnetAddress(t *testing.T) {
	for _, a := range []string{"100.64.0.0", "100.64.0.9", "100.100.100.100", "100.127.255.255"} {
		if !tailnode.IsTailnetAddress(netip.MustParseAddr(a)) {
			t.Errorf("%s is inside 100.64.0.0/10", a)
		}
	}
	for _, a := range []string{"100.63.255.255", "100.128.0.0", "10.0.0.1", "127.0.0.1", "203.0.113.9"} {
		if tailnode.IsTailnetAddress(netip.MustParseAddr(a)) {
			t.Errorf("%s is outside 100.64.0.0/10", a)
		}
	}
}

// probeHost runs the real public probe against host (a loopback listener's
// address) and returns its verdict.
func probeHost(t *testing.T, h string) tailnode.ProbeClass {
	t.Helper()
	// hang ceiling only, not an expectation of how long a probe takes
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	return tailnode.NewPublicProbe()(ctx, h)
}

// TestPublicProbeRealFailures protects the classification at the real
// boundary: the probe that production runs, pointed at local listeners that
// refuse, accept and hang up, and speak TLS with a certificate nothing
// trusts, returns the class each failure belongs to. It cannot show a
// success (no certificate the probe trusts exists here) or the machine's
// resolver; the owner's check on a live address covers those.
func TestPublicProbeRealFailures(t *testing.T) {
	t.Run("refused before connecting", func(t *testing.T) {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := ln.Addr().String()
		ln.Close()
		if got := probeHost(t, addr); got != tailnode.ProbeMacRefused {
			t.Errorf("class = %v, want %v", got, tailnode.ProbeMacRefused)
		}
	})
	t.Run("dropped after connecting", func(t *testing.T) {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer ln.Close()
		go func() {
			for {
				c, err := ln.Accept()
				if err != nil {
					return
				}
				c.Close()
			}
		}()
		if got := probeHost(t, ln.Addr().String()); !got.RouteFailure() {
			t.Errorf("class = %v, want a route failure", got)
		}
	})
	t.Run("tls certificate not trusted", func(t *testing.T) {
		srv := httptest.NewTLSServer(http.NotFoundHandler())
		defer srv.Close()
		if got := probeHost(t, strings.TrimPrefix(srv.URL, "https://")); got != tailnode.ProbeRouteTLS {
			t.Errorf("class = %v, want %v", got, tailnode.ProbeRouteTLS)
		}
	})
	t.Run("name inside the tailnet range", func(t *testing.T) {
		for _, h := range []string{"100.64.0.9", "100.127.255.254"} {
			if got := probeHost(t, h); got != tailnode.ProbeTailnetAddress {
				t.Errorf("%s: class = %v, want %v", h, got, tailnode.ProbeTailnetAddress)
			}
		}
	})
}

// TestProbeClassNames protects the contract with the app: the names a count
// is reported under are the names the app's diagnostics accept, so a renamed
// class would silently drop out of a report.
func TestProbeClassNames(t *testing.T) {
	want := map[tailnode.ProbeClass]string{
		tailnode.ProbeRouteDropped:     "dropped_during_tls",
		tailnode.ProbeRouteTLS:         "tls_failure",
		tailnode.ProbeRouteServerError: "server_error",
		tailnode.ProbeMacDNS:           "dns_failure",
		tailnode.ProbeMacNoRoute:       "no_route",
		tailnode.ProbeMacRefused:       "connect_refused",
		tailnode.ProbeMacTimeout:       "connect_timeout",
		tailnode.ProbeTailnetAddress:   "tailnet_address",
		tailnode.ProbeNodeOffline:      "node_offline",
		tailnode.ProbeNodeHealth:       "node_unhealthy",
		tailnode.ProbeStatusRead:       "status_read_failed",
	}
	for class, name := range want {
		if got := class.String(); got != name {
			t.Errorf("class %d is named %q, want %q", class, got, name)
		}
	}
}
