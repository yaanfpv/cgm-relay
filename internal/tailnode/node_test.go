package tailnode

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/nightscout"
	"github.com/yaanfpv/cgm-relay/internal/store"
	"golang.org/x/sys/unix"
	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"tailscale.com/net/portmapper"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/util/eventbus"
)

// portMappingDisabled asks a real tailscale portmapper client to probe and
// reports whether it refused because port mapping is switched off. The
// client's gateway lookup uses a static monitor with no gateway, so a probe
// that is not refused ends without sending a packet.
func portMappingDisabled(t *testing.T) bool {
	t.Helper()
	bus := eventbus.New()
	defer bus.Close()
	c := portmapper.NewClient(portmapper.Config{EventBus: bus, NetMon: netmon.NewStatic()})
	defer c.Close()
	_, err := c.Probe(context.Background())
	return errors.Is(err, portmapper.ErrPortMappingDisabled)
}

// TestBuiltInNodeRunsWithPortMappingDisabled checks that bringing the node
// up switches tailscale's port mapping off, and does it before the node's
// first contact with its control server, so the engine never probes the local
// network for a router to map a port on (which makes macOS ask the person to
// let the app find devices on local networks). The control server is a local
// fake; the node must still come up as far as asking for a sign-in.
func TestBuiltInNodeRunsWithPortMappingDisabled(t *testing.T) {
	// The knob is process-wide, so start from a known unset value and leave
	// it unset for the tests after this one.
	envknob.Setenv("TS_DISABLE_PORTMAPPER", "")
	t.Cleanup(func() { envknob.Setenv("TS_DISABLE_PORTMAPPER", "") })
	if portMappingDisabled(t) {
		t.Fatal("port mapping is already disabled before the node starts; the check cannot tell")
	}

	ctrl := &testcontrol.Server{RequireAuth: true}
	var once sync.Once
	firstContact := make(chan bool, 1)
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		once.Do(func() { firstContact <- portMappingDisabled(t) })
		ctrl.ServeHTTP(w, r)
	}))
	ctrl.HTTPTestServer = hs
	t.Cleanup(hs.Close)

	needsLogin := make(chan struct{})
	var closeNeedsLogin sync.Once
	n := Start(Options{
		StateDir:   filepath.Join(t.TempDir(), "ts"),
		Hostname:   "relay-test",
		Handler:    http.NotFoundHandler(),
		NewServer:  func(h http.Handler) *http.Server { return &http.Server{Handler: h} },
		controlURL: hs.URL,
		Logf: func(format string, args ...any) {
			if len(args) == 1 && args[0] == StateNeedsLogin {
				closeNeedsLogin.Do(func() { close(needsLogin) })
			}
		},
	})
	t.Cleanup(n.Close)

	// hang ceiling only, not an expectation of how long the node takes
	hang := time.After(2 * time.Minute)
	select {
	case off := <-firstContact:
		if !off {
			t.Error("at the node's first contact with its control server, port mapping was still enabled")
		}
	case <-hang:
		t.Fatal("the node never contacted its control server")
	}
	select {
	case <-needsLogin:
	case <-hang:
		t.Fatalf("the node never reached the sign-in state; last status %+v", n.Status())
	}
	if !portMappingDisabled(t) {
		t.Error("with the node up, port mapping is enabled")
	}
	if got := n.Status().State; got != StateNeedsLogin {
		t.Errorf("status state = %q, want %q", got, StateNeedsLogin)
	}
}

// TestRestartKeepsStateDirectory protects the sign-in across a repair: the
// restart that follows an address that stopped answering must bring the
// node up again on the folder that holds its keys, so the person is not
// asked to sign in again and the machine does not appear as a second
// device. The fake control server stops at the sign-in step, so what this
// can show is the folder: the same one is handed to the new server, its
// contents are unchanged, its mode is still 0700 and nothing is created
// beside it. That the node key itself survives a restart needs a signed-in
// node and a live address, so it is not covered here.
func TestRestartKeepsStateDirectory(t *testing.T) {
	ctrl := &testcontrol.Server{RequireAuth: true}
	hs := httptest.NewServer(ctrl)
	ctrl.HTTPTestServer = hs
	t.Cleanup(hs.Close)

	parent := t.TempDir()
	dir := filepath.Join(parent, "ts")
	states := make(chan string, 64)
	n := Start(Options{
		StateDir:   dir,
		Hostname:   "relay-test",
		Handler:    http.NotFoundHandler(),
		NewServer:  func(h http.Handler) *http.Server { return &http.Server{Handler: h} },
		controlURL: hs.URL,
		Logf: func(format string, args ...any) {
			if len(args) == 1 {
				if s, ok := args[0].(string); ok {
					select {
					case states <- s:
					default:
					}
				}
			}
		},
	})
	t.Cleanup(n.Close)

	// hang ceiling only, not an expectation of how long the node takes
	hang := time.After(2 * time.Minute)
	waitSignIn := func(what string) {
		t.Helper()
		for {
			select {
			case s := <-states:
				if s == StateNeedsLogin {
					return
				}
			case <-hang:
				t.Fatalf("the node never reached the sign-in state %s; last status %+v", what, n.Status())
			}
		}
	}
	waitSignIn("before the restart")
	before := readDir(t, dir)

	if err := n.Restart(context.Background()); err != nil {
		t.Fatalf("Restart: %v", err)
	}
	waitSignIn("after the restart")

	n.mu.Lock()
	srv := n.srv
	n.mu.Unlock()
	if srv == nil || srv.Dir != dir {
		t.Errorf("the restarted server's folder is %v, want %s", srv, dir)
	}
	after := readDir(t, dir)
	if len(before) == 0 {
		t.Fatal("the state folder was empty before the restart; the check cannot tell")
	}
	if len(after) != len(before) {
		t.Errorf("state folder files %d after, %d before", len(after), len(before))
	}
	for name, b := range before {
		if got, ok := after[name]; !ok || got != b {
			t.Errorf("state file %s changed across the restart", name)
		}
	}
	if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("state folder after the restart: %v, %v; want mode 0700", fi, err)
	}
	if es, err := os.ReadDir(parent); err != nil || len(es) != 1 {
		t.Errorf("the restart left %d entries beside the state folder, want only it (%v)", len(es), err)
	}
}

// readDir returns the content of every file in dir by name.
func readDir(t *testing.T, dir string) map[string]string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	out := map[string]string{}
	for _, e := range es {
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		out[e.Name()] = string(b)
	}
	return out
}

// The tests below run the whole node against a fake Tailscale node that
// stands in for what a test cannot have: a tailnet whose policy changes, the
// public internet and a resolver. The fake is driven by events, never by the
// clock: the public tests are scripted, and every wait the node makes between
// them is held at the injected sleep until the test lets it go, so the test
// looks at a node that is standing still. Not covered here: a real restart,
// resolver or relay.

const (
	fakeHost = "relay.example-tailnet.ts.net"
	// hangCeiling only ends a test that waits for an event that never comes.
	hangCeiling = 2 * time.Minute
)

var fakeEpoch = time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)

func fakeStamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }

type testClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *testClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func (c *testClock) set(t time.Time) {
	c.mu.Lock()
	c.t = t
	c.mu.Unlock()
}

type startArgs struct{ dir, hostname string }

// fakeTailnet is the tailnet, the internet and the clock of one test.
type fakeTailnet struct {
	t     *testing.T
	dir   string
	clock *testClock
	node  *Node

	mu          sync.Mutex
	events      []string
	logs        []string
	states      []string
	starts      []startArgs
	allowed     bool
	listenErr   error
	onRefusal   func(refusals int)
	refusals    int
	firstListen time.Time
	expiry      *time.Time
	result      ProbeClass
	cur         *fakeNode
	loginStarts int
	ln          net.Listener                    // the public listener ListenFunnel hands out, when set
	handler     http.Handler                    // the node's Handler, when set
	newServer   func(http.Handler) *http.Server // the node's NewServer, when set
	nodeLogf    func(string, ...any)            // the log hook the node handed the running server
	funnelOn    bool                            // whether the server's serve config allows Funnel
	offTimes    []time.Time                     // when Funnel was switched off
	logoutErr   error                           // what the fake's Logout answers
	logoutHangs bool                            // Logout waits for its context to end

	probes   atomic.Int64
	stateCh  chan string
	sleeping chan time.Duration
	release  chan struct{}
	holdAll  atomic.Bool // hold every wait, even before the first public test
	nextAsk  chan struct{}
	evNotify chan struct{} // a nudge for every event the fake logs
}

func newFakeTailnet(t *testing.T) *fakeTailnet {
	return &fakeTailnet{
		t: t, dir: filepath.Join(t.TempDir(), "ts"), clock: &testClock{t: fakeEpoch},
		allowed: true, result: ProbeNameNotPublished,
		stateCh: make(chan string, 1024), sleeping: make(chan time.Duration, 1024),
		release: make(chan struct{}), nextAsk: make(chan struct{}, 1024),
		evNotify: make(chan struct{}, 1024),
	}
}

func (tn *fakeTailnet) event(s string) {
	tn.mu.Lock()
	tn.events = append(tn.events, s)
	tn.mu.Unlock()
	select {
	case tn.evNotify <- struct{}{}:
	default:
	}
}

func (tn *fakeTailnet) log() []string {
	tn.mu.Lock()
	defer tn.mu.Unlock()
	return slices.Clone(tn.events)
}

func (tn *fakeTailnet) setResult(c ProbeClass) {
	tn.mu.Lock()
	tn.result = c
	tn.mu.Unlock()
}

func (tn *fakeTailnet) setAllowed(a bool) {
	tn.mu.Lock()
	tn.allowed = a
	tn.mu.Unlock()
}

func (tn *fakeTailnet) startCount() int {
	tn.mu.Lock()
	defer tn.mu.Unlock()
	return len(tn.starts)
}

// logf is the node's Logf: it keeps every line and the history of states.
func (tn *fakeTailnet) logf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	tn.mu.Lock()
	tn.logs = append(tn.logs, line)
	state := ""
	if len(args) == 1 {
		if s, ok := args[0].(string); ok {
			state = s
			tn.states = append(tn.states, s)
		}
	}
	tn.mu.Unlock()
	if state != "" {
		select {
		case tn.stateCh <- state:
		default:
		}
	}
}

// sleep is the node's clock for every wait. Before the first public test it
// returns at once, since nothing there is being measured. From then on it
// holds until the test releases it, and then moves the clock by the wait.
func (tn *fakeTailnet) sleep(ctx context.Context, d time.Duration) bool {
	if ctx.Err() != nil {
		return false
	}
	if tn.probes.Load() == 0 && !tn.holdAll.Load() {
		tn.clock.advance(d)
		return true
	}
	tn.event("sleep:" + d.String())
	tn.sleeping <- d
	select {
	case <-tn.release:
		tn.clock.advance(d)
		return true
	case <-ctx.Done():
		return false
	}
}

// probe is the node's public test: it answers whatever the test last set.
func (tn *fakeTailnet) probe(_ context.Context, h string) ProbeClass {
	tn.event("probe")
	tn.probes.Add(1)
	if h != fakeHost {
		tn.t.Errorf("probe asked about %q, want %q", h, fakeHost)
	}
	tn.mu.Lock()
	defer tn.mu.Unlock()
	return tn.result
}

func (tn *fakeTailnet) start(dir, hostname string, logf func(string, ...any)) (nodeAPI, error) {
	tn.mu.Lock()
	tn.nodeLogf = logf
	tn.starts = append(tn.starts, startArgs{dir, hostname})
	n := len(tn.starts)
	f := &fakeNode{tn: tn, gen: n, notes: make(chan ipn.Notify, 16), closed: make(chan struct{})}
	running := ipn.Running
	f.notes <- ipn.Notify{State: &running}
	tn.cur = f
	tn.events = append(tn.events, fmt.Sprintf("start#%d", n))
	tn.mu.Unlock()
	return f, nil
}

// run starts the node under test.
func (tn *fakeTailnet) run() *Node {
	handler, newServer := tn.handler, tn.newServer
	if handler == nil {
		handler = http.NotFoundHandler()
	}
	if newServer == nil {
		newServer = func(h http.Handler) *http.Server { return &http.Server{Handler: h} }
	}
	n := Start(Options{
		StateDir: tn.dir, Hostname: "relay-test",
		Handler:   handler,
		NewServer: newServer,
		Logf:      tn.logf, now: tn.clock.Now, sleep: tn.sleep, probe: tn.probe, startNode: tn.start,
	})
	tn.t.Cleanup(n.Close)
	tn.node = n
	return n
}

// waitSleep waits until the node is standing in a wait between two public
// tests, and returns how long that wait is.
func (tn *fakeTailnet) waitSleep() time.Duration {
	tn.t.Helper()
	select {
	case d := <-tn.sleeping:
		return d
	case <-time.After(hangCeiling):
		tn.t.Fatalf("the node never reached a wait between public tests; events %v", tn.log())
		return 0
	}
}

// letGo lets the held wait end.
func (tn *fakeTailnet) letGo() {
	tn.t.Helper()
	select {
	case tn.release <- struct{}{}:
	case <-time.After(hangCeiling):
		tn.t.Fatalf("no wait was held; events %v", tn.log())
	}
}

// waitState waits for the node to log a change to state.
func (tn *fakeTailnet) waitState(state string) {
	tn.t.Helper()
	for {
		select {
		case s := <-tn.stateCh:
			if s == state {
				return
			}
		case <-time.After(hangCeiling):
			tn.t.Fatalf("the node never logged %q; states %v, status %+v", state, tn.stateHistory(), tn.node.Status())
		}
	}
}

func (tn *fakeTailnet) stateHistory() []string {
	tn.mu.Lock()
	defer tn.mu.Unlock()
	return slices.Clone(tn.states)
}

// press presses Try Again and returns once the node says its test is done.
func (tn *fakeTailnet) press() {
	tn.t.Helper()
	tn.event("press")
	done := make(chan error, 1)
	go func() { done <- tn.node.TryAgain(context.Background()) }()
	select {
	case err := <-done:
		if err != nil {
			tn.t.Fatalf("TryAgain: %v", err)
		}
	case <-time.After(hangCeiling):
		tn.t.Fatalf("TryAgain never returned; events %v", tn.log())
	}
}

// funnelCaps is what the node's status says about Funnel when it is allowed.
func funnelCaps() tailcfg.NodeCapMap {
	return tailcfg.NodeCapMap{
		tailcfg.CapabilityHTTPS: nil,
		tailcfg.NodeAttrFunnel:  nil,
		tailcfg.NodeCapability(string(tailcfg.CapabilityFunnelPorts) + "?ports=443,8443,10000"): nil,
	}
}

// fakeNode is one generation of the node: one start of the Tailscale server.
type fakeNode struct {
	tn     *fakeTailnet
	gen    int
	notes  chan ipn.Notify
	closed chan struct{}
	once   sync.Once
}

func (f *fakeNode) Status(context.Context) (*ipnstate.Status, error) {
	f.tn.mu.Lock()
	defer f.tn.mu.Unlock()
	self := &ipnstate.PeerStatus{Online: true, KeyExpiry: f.tn.expiry}
	if f.tn.allowed {
		self.CapMap = funnelCaps()
	}
	return &ipnstate.Status{
		Self: self, CertDomains: []string{fakeHost},
		TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.7")},
	}, nil
}

func (f *fakeNode) QueryFunnel(context.Context) (*tailcfg.QueryFeatureResponse, error) {
	f.tn.mu.Lock()
	defer f.tn.mu.Unlock()
	if f.tn.allowed {
		return &tailcfg.QueryFeatureResponse{Complete: true}, nil
	}
	return &tailcfg.QueryFeatureResponse{URL: "https://login.tailscale.com/f/funnel"}, nil
}

func (f *fakeNode) ListenFunnel(context.Context) (net.Listener, error) {
	f.tn.mu.Lock()
	if !f.tn.allowed {
		f.tn.refusals++
		n := f.tn.refusals
		err := f.tn.listenErr
		hook := f.tn.onRefusal
		f.tn.events = append(f.tn.events, "listen-refused")
		f.tn.mu.Unlock()
		if hook != nil {
			hook(n)
		}
		if err == nil {
			err = errors.New("listen refused")
		}
		return nil, err
	}
	if f.tn.firstListen.IsZero() {
		f.tn.firstListen = f.tn.clock.Now()
	}
	f.tn.funnelOn = true
	f.tn.events = append(f.tn.events, fmt.Sprintf("listen-ok#%d", f.gen))
	ln := f.tn.ln
	f.tn.mu.Unlock()
	if ln != nil {
		return ln, nil
	}
	return &fakeListener{done: make(chan struct{})}, nil
}

func (f *fakeNode) WarmCertificate(context.Context, string) {}

// SetFunnelAllowed switches the AllowFunnel entry of the serve config. The
// listener stays open through it. Setting the state the config is already in is
// the unchanged re-apply that Tailscale ignores, so it is reported.
func (f *fakeNode) SetFunnelAllowed(_ context.Context, allowed bool) error {
	f.tn.mu.Lock()
	same := f.tn.funnelOn == allowed
	f.tn.funnelOn = allowed
	if !allowed {
		f.tn.offTimes = append(f.tn.offTimes, f.tn.clock.Now())
	}
	f.tn.mu.Unlock()
	if same {
		f.tn.t.Errorf("Funnel set to %v while the serve config already had it so: an unchanged config", allowed)
	}
	if allowed {
		f.tn.event(fmt.Sprintf("funnel-on#%d", f.gen))
	} else {
		f.tn.event(fmt.Sprintf("funnel-off#%d", f.gen))
	}
	return nil
}

func (f *fakeNode) StartLogin(context.Context) error {
	f.tn.mu.Lock()
	f.tn.loginStarts++
	f.tn.events = append(f.tn.events, "start-login")
	f.tn.mu.Unlock()
	u := "https://login.tailscale.com/a/abc123"
	f.notes <- ipn.Notify{BrowseToURL: &u}
	return nil
}

// Logout is the node telling its control server to expire this machine's key.
// It is logged when it starts and again when it returns, so a test can order
// it against the node's Close.
func (f *fakeNode) Logout(ctx context.Context) error {
	f.tn.event(fmt.Sprintf("logout#%d", f.gen))
	f.tn.mu.Lock()
	err, hangs := f.tn.logoutErr, f.tn.logoutHangs
	f.tn.mu.Unlock()
	if hangs {
		<-ctx.Done()
		err = ctx.Err()
	}
	f.tn.event(fmt.Sprintf("logout-done#%d", f.gen))
	return err
}

func (f *fakeNode) Close() error {
	f.once.Do(func() {
		f.tn.event(fmt.Sprintf("close#%d", f.gen))
		close(f.closed)
	})
	return nil
}

func (f *fakeNode) Watch(ctx context.Context) (ipnWatcher, error) {
	return &fakeWatcher{f: f, ctx: ctx}, nil
}

type fakeWatcher struct {
	f   *fakeNode
	ctx context.Context
}

func (w *fakeWatcher) Next() (ipn.Notify, error) {
	select {
	case w.f.tn.nextAsk <- struct{}{}:
	default:
	}
	select {
	case n := <-w.f.notes:
		return n, nil
	case <-w.f.closed:
		return ipn.Notify{}, errors.New("closed")
	case <-w.ctx.Done():
		return ipn.Notify{}, w.ctx.Err()
	}
}

func (w *fakeWatcher) Close() error { return nil }

// fakeListener is a public listener that takes no connection.
type fakeListener struct {
	once sync.Once
	done chan struct{}
}

func (l *fakeListener) Accept() (net.Conn, error) {
	<-l.done
	return nil, net.ErrClosed
}
func (l *fakeListener) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *fakeListener) Addr() net.Addr { return &net.TCPAddr{} }

// statusJSON is the node's status as the app reads it.
func statusJSON(t *testing.T, n *Node) (map[string]any, string) {
	t.Helper()
	b, err := json.Marshal(n.Status())
	if err != nil {
		t.Fatal(err)
	}
	m := map[string]any{}
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m, strings.ToLower(string(b))
}

// holdWaits makes every wait the node makes stand at the injected sleep, also
// before the first public test, so a test can look at the node while it waits.
func (tn *fakeTailnet) holdWaits() { tn.holdAll.Store(true) }

// untilState releases the waits the node makes until it logs state.
func (tn *fakeTailnet) untilState(state string) {
	tn.t.Helper()
	for {
		select {
		case s := <-tn.stateCh:
			if s == state {
				return
			}
		case <-tn.sleeping:
			go func() {
				select {
				case tn.release <- struct{}{}:
				case <-time.After(hangCeiling):
				}
			}()
		case <-time.After(hangCeiling):
			tn.t.Fatalf("the node never logged %q; events %v", state, tn.log())
		}
	}
}

// waitForEvent returns once an event with prefix has been logged.
func (tn *fakeTailnet) waitForEvent(prefix string) {
	tn.t.Helper()
	for tn.count(prefix) == 0 {
		select {
		case <-tn.evNotify:
		case <-time.After(hangCeiling):
			tn.t.Fatalf("no %q event; events %v", prefix, tn.log())
		}
	}
}

// waitingForFunnel runs a node whose tailnet does not allow Funnel yet, lets
// Funnel become allowed while the node stands in a wait, and returns when the
// node next stands in a wait, with the length of that wait.
func (tn *fakeTailnet) waitingForFunnel() time.Duration {
	tn.t.Helper()
	tn.allowed = false
	tn.listenErr = errors.New("Funnel not available; \"funnel\" node attribute not set")
	tn.holdWaits()
	tn.run()
	tn.waitSleep()
	if tn.count("listen-refused") == 0 {
		tn.t.Fatalf("the node was never refused, so the check cannot tell: %v", tn.log())
	}
	tn.setAllowed(true)
	tn.letGo()
	d := tn.waitSleep()
	if tn.count("listen-ok#") != 0 {
		tn.t.Fatalf("the node registered Funnel before any reconnect: %v", tn.log())
	}
	return d
}

// TestNodeListensAfterTheReconnectWhenFunnelBecomesAllowed protects the first
// public test of a new address. A node that ran while its tailnet did not
// allow Funnel, and finds it allowed, waits for the control server to reset
// its session before it registers Funnel, because a registration made just
// before that reset is dropped a minute later. It registers on the same
// running node within seconds of the reset, and shows publishing while it waits.
func TestNodeListensAfterTheReconnectWhenFunnelBecomesAllowed(t *testing.T) {
	for _, line := range reconnectLogLines {
		t.Run(line, func(t *testing.T) {
			tn := newFakeTailnet(t)
			tn.waitingForFunnel()
			m, text := statusJSON(t, tn.node)
			if m["ts_state"] != "publishing" || m["ts_error"] != nil || m["ts_tailscale_error"] != nil || strings.Contains(text, "error") {
				t.Errorf("status while waiting for the reconnect: %v", m)
			}
			tn.nodeLog(line)
			tn.waitForEvent("listen-ok#")
			evs := tn.log()
			if slices.Index(evs, "listen-ok#1") < slices.Index(evs, "log:"+line) {
				t.Errorf("Funnel was registered before the reconnect line: %v", evs)
			}
			if slices.Contains(evs, "probe") && slices.Index(evs, "probe") < slices.Index(evs, "listen-ok#1") {
				t.Errorf("the first public test came before Funnel was registered: %v", evs)
			}
			if tn.count("start#") != 1 || tn.count("close#") != 0 {
				t.Errorf("a node was started or closed because Funnel turned on: %v", evs)
			}
			tn.mu.Lock()
			starts := slices.Clone(tn.starts)
			tn.mu.Unlock()
			if len(starts) != 1 || starts[0].dir != tn.dir {
				t.Errorf("starts %+v, want one on the folder %s", starts, tn.dir)
			}
			tn.setResult(ProbeOK)
			tn.untilState("running")
			if tn.count("start#") != 1 || tn.count("close#") != 0 {
				t.Errorf("a node was started or closed by the time the address answered: %v", tn.log())
			}
			for _, s := range tn.stateHistory() {
				if s == StateError {
					t.Errorf("setup passed through the error state: %v", tn.stateHistory())
				}
			}
		})
	}
}

// TestNodeListensAfterAMinuteWithoutAReconnect protects the address from a
// wait that never ends: when Funnel became allowed without the control server
// resetting the session, the node registers Funnel after 60 seconds of its own
// clock anyway.
func TestNodeListensAfterAMinuteWithoutAReconnect(t *testing.T) {
	tn := newFakeTailnet(t)
	d := tn.waitingForFunnel()
	waited := d
	for tn.count("listen-ok#") == 0 {
		if waited > time.Minute {
			t.Fatalf("waited %v of the node's clock with no registration: %v", waited, tn.log())
		}
		tn.letGo()
		select {
		case d := <-tn.sleeping:
			waited += d
		case <-tn.evNotify:
		case <-time.After(hangCeiling):
			t.Fatalf("the node neither waited nor registered: %v", tn.log())
		}
	}
	if waited > time.Minute {
		t.Errorf("registered after %v of the node's clock, want at most a minute", waited)
	}
}

// TestNodeDoesNotRestartWhenFunnelWasAllowedAllAlong protects the other side:
// a node whose tailnet allowed Funnel from the start is already registered
// for it, and a restart there would only delay the address.
func TestNodeDoesNotRestartWhenFunnelWasAllowedAllAlong(t *testing.T) {
	tn := newFakeTailnet(t)
	tn.holdWaits()
	tn.run()
	tn.waitSleep()
	evs := tn.log()
	if l, s := slices.Index(evs, "listen-ok#1"), slices.IndexFunc(evs, func(e string) bool { return strings.HasPrefix(e, "sleep:") }); l < 0 || (s >= 0 && s < l) {
		t.Errorf("the node waited before registering Funnel although it was allowed from the start: %v", evs)
	}
	tn.setResult(ProbeOK)
	tn.letGo()
	tn.waitState("running")
	if got := tn.startCount(); got != 1 {
		t.Errorf("%d starts, want 1 (events %v)", got, tn.log())
	}
}

// TestNodeKeepsPublishingWithBackoff protects the wait for a new address: every
// kind of test that fails before the first answer, a name that does not exist
// yet, a connection the relay drops, a certificate or a server error, and a
// name that resolves inside the tailnet, leaves the state publishing, with no
// error and no word about the internet, and the next test comes after 5
// seconds, doubling to 30.
func TestNodeKeepsPublishingWithBackoff(t *testing.T) {
	tn := newFakeTailnet(t)
	failing := []ProbeClass{
		ProbeNameNotPublished, ProbeNameNotPublished, ProbeRouteDropped, ProbeRouteTLS,
		ProbeRouteServerError, ProbeTailnetAddress, ProbeNameNotPublished, ProbeRouteDropped,
	}
	tn.setResult(failing[0])
	n := tn.run()
	var waits []time.Duration
	for i, c := range failing {
		if i > 0 {
			tn.setResult(c)
			tn.letGo()
		}
		waits = append(waits, tn.waitSleep())
		m, text := statusJSON(t, n)
		if m["ts_state"] != "publishing" || strings.Contains(text, "internet") || m["ts_error"] != nil {
			t.Fatalf("after a test that failed as %v: %v", c, m)
		}
		if m["ts_publishing_since"] != fakeStamp(tn.firstListen) {
			t.Errorf("ts_publishing_since = %v, want %s, when the address began to be served", m["ts_publishing_since"], fakeStamp(tn.firstListen))
		}
	}
	want := []time.Duration{5 * time.Second, 10 * time.Second, 20 * time.Second, 30 * time.Second, 30 * time.Second, 30 * time.Second, 30 * time.Second, 30 * time.Second}
	if !slices.Equal(waits, want) {
		t.Errorf("waits between tests %v, want %v", waits, want)
	}
	tn.setResult(ProbeOK)
	tn.letGo()
	tn.waitState("running")
}

// TestNodeNotReachableAfterFifteenMinutesAndTryAgainReRegistersWithoutRestart protects the
// end of the wait: with no answer after fifteen minutes the state is
// not-reachable and carries the last text Tailscale gave, which a failed
// listen earlier produced, and its class. Tests go on, so an answer that
// comes later still ends the setup by itself. Try Again then re-registers
// Funnel on the running node (the serve config's off and on) and tests at
// once, with no wait between the press and the test, and the publishing window
// starts again.
func TestNodeNotReachableAfterFifteenMinutesAndTryAgainReRegistersWithoutRestart(t *testing.T) {
	text := tailscaleTextForTest(t)
	tn := newFakeTailnet(t)
	tn.allowed = false
	tn.listenErr = errors.New(text)
	tn.onRefusal = func(int) { tn.setAllowed(true) }
	n := tn.run()
	tn.waitSleep()

	since := tn.firstListen
	tn.clock.set(since.Add(14*time.Minute + 30*time.Second))
	tn.letGo()
	tn.waitSleep()
	m, txt := statusJSON(t, n)
	if m["ts_state"] != "publishing" || m["ts_tailscale_error"] != text || m["ts_error_class"] != "node_attribute_missing" || strings.Contains(txt, "internet") {
		t.Fatalf("just under fifteen minutes: %v", m)
	}

	tn.clock.set(since.Add(15 * time.Minute))
	tn.letGo()
	tn.waitSleep()
	m, txt = statusJSON(t, n)
	if m["ts_state"] != "not-reachable" || m["ts_tailscale_error"] != text || m["ts_error_class"] != "node_attribute_missing" || m["ts_error"] != nil || strings.Contains(txt, "internet") {
		t.Fatalf("after fifteen minutes: %v", m)
	}

	pressAt := tn.clock.Now()
	tn.setResult(ProbeRouteDropped)
	tn.press()
	evs := tn.log()
	at := slices.Index(evs, "press")
	rest := evs[at+1:]
	probeAt := slices.Index(rest, "probe")
	if probeAt < 0 {
		t.Fatalf("the press made no test: %v", rest)
	}
	before := rest[:probeAt]
	off, on := slices.Index(before, "funnel-off#1"), slices.Index(before, "funnel-on#1")
	if off < 0 || on < off {
		t.Fatalf("after the press Funnel must be switched off and on, then tested: %v", rest)
	}
	if got := countPrefix(before, "funnel-off"); got != 1 {
		t.Errorf("%d re-registrations before the press's test, want 1: %v", got, rest)
	}
	for _, e := range before {
		if strings.HasPrefix(e, "sleep:") {
			t.Errorf("a wait between the press and the test: %v", rest)
		}
	}
	if tn.startCount() != 1 || tn.count("close#") != 0 {
		t.Errorf("the press closed or started a node: %v", tn.log())
	}
	m, _ = statusJSON(t, n)
	if m["ts_state"] != "publishing" || m["ts_publishing_since"] != fakeStamp(pressAt) {
		t.Errorf("after a press whose test failed: %v, want publishing again since %s", m, fakeStamp(pressAt))
	}

	// The next press, with the answer there, finishes the setup.
	tn.waitSleep()
	tn.setResult(ProbeOK)
	tn.clock.advance(6 * time.Minute)
	tn.press()
	tn.waitState("running")
}

// TestNodeAnswerAfterTheWindowStillFinishesSetup protects setup finishing
// without a press: once the window has passed and the state is not-reachable,
// the next ordinary test that is answered makes the address ready.
func TestNodeAnswerAfterTheWindowStillFinishesSetup(t *testing.T) {
	tn := newFakeTailnet(t)
	n := tn.run()
	tn.waitSleep()
	tn.clock.set(tn.firstListen.Add(16 * time.Minute))
	tn.letGo()
	tn.waitSleep()
	if m, _ := statusJSON(t, n); m["ts_state"] != "not-reachable" {
		t.Fatalf("after sixteen minutes: %v, want not-reachable", m)
	}
	tn.setResult(ProbeOK)
	tn.letGo()
	tn.waitState("running")
}

// TestNodeTryAgainKeepsTheReRegisterCaps protects the node and the control
// server from a loop when Try Again is pressed over and over: a press always
// tests at once, but re-registers Funnel at most once in five minutes and
// three times in an hour, and it never closes or starts a node.
func TestNodeTryAgainKeepsTheReRegisterCaps(t *testing.T) {
	tn := newFakeTailnet(t)
	tn.setResult(ProbeRouteDropped)
	tn.run()
	tn.waitSleep()
	var acted []int
	for _, gap := range []time.Duration{0, time.Minute, 5 * time.Minute, 5 * time.Minute, 5 * time.Minute} {
		tn.clock.advance(gap)
		beforeProbes, beforeOffs := int(tn.probes.Load()), tn.count("funnel-off")
		tn.press()
		if int(tn.probes.Load()) <= beforeProbes {
			t.Errorf("a press after %v made no test", gap)
		}
		acted = append(acted, tn.count("funnel-off")-beforeOffs)
		tn.waitSleep()
	}
	if want := []int{1, 0, 1, 1, 0}; !slices.Equal(acted, want) {
		t.Errorf("re-registrations made by each press %v, want %v", acted, want)
	}
	if tn.startCount() != 1 || tn.count("close#") != 0 {
		t.Errorf("a press closed or started a node: %v", tn.log())
	}
}

// TestNodeFirstFailedTestAfterARestartReRegistersBeforeTheNextRestart
// protects the repair ladder's last rung from undoing itself: a restarted
// node has a registration the servers may not have taken yet, so the first
// failed public test after any restart switches Funnel off and on, once, on
// the new node, before the ladder may restart again, however many restarts
// the ladder makes. The failed tests are driven by presses, since a serving
// node's own tests wait on a real timer. A press on a serving node never
// re-registers Funnel itself, so any toggle seen on a new node is the failed
// test's.
func TestNodeFirstFailedTestAfterARestartReRegistersBeforeTheNextRestart(t *testing.T) {
	tn := newFakeTailnet(t)
	tn.runReady()
	for i := 0; i < 2; i++ {
		tn.clock.advance(5 * time.Minute)
		tn.settle(time.Hour)
	}
	spent := tn.clock.Now()
	tn.setResult(ProbeRouteDropped)
	for i := 0; i < 40 && tn.startCount() < 3; i++ {
		tn.clock.advance(time.Minute)
		tn.settle(time.Hour)
	}
	evs := tn.log()
	if tn.startCount() < 2 {
		t.Fatalf("the ladder never restarted the node, so the check cannot tell: %v", evs)
	}
	if over := tn.clock.Now().Sub(spent); over >= 50*time.Minute {
		t.Fatalf("%v of failed tests: the failed tests ran past the hour, so the check cannot tell", over)
	}
	for gen := 2; gen <= tn.startCount(); gen++ {
		started := slices.Index(evs, fmt.Sprintf("start#%d", gen))
		end := len(evs)
		if n := slices.Index(evs, fmt.Sprintf("start#%d", gen+1)); n >= 0 {
			end = n
		}
		window := evs[started:end]
		if !slices.Contains(window, "probe") {
			continue
		}
		off, on := slices.Index(window, fmt.Sprintf("funnel-off#%d", gen)), slices.Index(window, fmt.Sprintf("funnel-on#%d", gen))
		if off < 0 || on < off || countPrefix(window, "funnel-off") != 1 {
			t.Errorf("after restart %d the failed tests made %d re-registrations on the new node before the next restart, want exactly one: %v", gen-1, countPrefix(window, "funnel-off"), window)
		}
	}
}

// countPrefix is how many of evs begin with prefix.
func countPrefix(evs []string, prefix string) int {
	n := 0
	for _, e := range evs {
		if strings.HasPrefix(e, prefix) {
			n++
		}
	}
	return n
}

// TestNodeReportsKeyExpiry protects the sign-in warning at its source: the
// time the node's key expires, as the node reports it, reaches the status.
func TestNodeReportsKeyExpiry(t *testing.T) {
	tn := newFakeTailnet(t)
	exp := fakeEpoch.Add(10 * 24 * time.Hour)
	tn.expiry = &exp
	n := tn.run()
	tn.waitSleep()
	if got := n.Status().KeyExpiry; got != fakeStamp(exp) {
		t.Errorf("KeyExpiry = %q, want %q", got, fakeStamp(exp))
	}
}

// TestNodeStartSignInStartsTheFlow protects the Sign In Again button's
// engine side: it asks the node to start its interactive sign-in once, and
// the page the node then names is kept for the app, on a node that is still
// running and answering.
func TestNodeStartSignInStartsTheFlow(t *testing.T) {
	tn := newFakeTailnet(t)
	tn.setResult(ProbeOK)
	n := tn.run()
	tn.waitState("running")
	for len(tn.nextAsk) > 0 {
		<-tn.nextAsk
	}
	if err := n.StartSignIn(context.Background()); err != nil {
		t.Fatalf("StartSignIn: %v", err)
	}
	select {
	case <-tn.nextAsk:
	case <-time.After(hangCeiling):
		t.Fatal("the node never took the page it was given")
	}
	tn.mu.Lock()
	starts := tn.loginStarts
	tn.mu.Unlock()
	if starts != 1 {
		t.Errorf("the sign-in flow was started %d times, want once", starts)
	}
	if got := n.Status().SignInAgainURL; got != "https://login.tailscale.com/a/abc123" {
		t.Errorf("SignInAgainURL = %q, want the page the node named", got)
	}
	if got := n.Status().State; got != StateRunning {
		t.Errorf("state %q after asking for a sign-in, want running: the address keeps working until the key expires", got)
	}
}

// TestNodeKeepsTailscaleTextOutOfDiagnostics protects what leaves the
// status as diagnostics: a refused listen whose text names an address and the
// host is kept for the person in the status, but the counts, and every line
// the node logs, carry only names the engine defines.
func TestNodeKeepsTailscaleTextOutOfDiagnostics(t *testing.T) {
	text := "listen tcp 100.64.0.9:443: bind: address already in use (" + fakeHost + ")"
	tn := newFakeTailnet(t)
	tn.allowed = false
	tn.listenErr = errors.New(text)
	tn.onRefusal = func(n int) {
		if n == 2 {
			tn.setAllowed(true)
		}
	}
	n := tn.run()
	tn.waitSleep()
	m, _ := statusJSON(t, n)
	if m["ts_tailscale_error"] != text || m["ts_error_class"] != "listen_failed" {
		t.Errorf("status %v, want the text and class listen_failed", m)
	}
	known := map[string]bool{"ingress_denied": true, "handshake": true}
	for i := 0; i < 32; i++ {
		if name := ProbeClass(i).String(); name != "" {
			known[name] = true
		}
	}
	for k := range n.mon.Counts() {
		if !known[k] {
			t.Errorf("count under %q, which the engine does not define", k)
		}
	}
	tn.mu.Lock()
	logs := slices.Clone(tn.logs)
	tn.mu.Unlock()
	for _, l := range logs {
		if strings.Contains(l, "100.64.0.9") || strings.Contains(l, "ts.net") || strings.Contains(l, "address already in use") {
			t.Errorf("a log line carries the Tailscale text: %q", l)
		}
	}
}

func tailscaleTextForTest(t *testing.T) string {
	t.Helper()
	err := ipn.NodeCanFunnel(&ipnstate.PeerStatus{CapMap: tailcfg.NodeCapMap{tailcfg.CapabilityHTTPS: nil}})
	if err == nil {
		t.Fatal("the node can funnel; the check cannot produce an error text")
	}
	return err.Error()
}

// The tests below follow a node whose control connection drops and returns.
// Tailscale's servers can lose a node's Funnel registration across such a
// reconnect, and the node's own log is the only place it says so. The fake
// records every change of the serve config, so these tests can show that the
// registration is switched off and on, in order, and left alone otherwise.
// Whether the real servers then take the node back needs a real tailnet, so
// it is not covered here.

const (
	// reregisterWithin is how long after a reconnect line the node may take to
	// re-register Funnel.
	reregisterWithin = 10 * time.Second
	// reregisterGap is the least time between two re-registrations.
	reregisterGap = 30 * time.Second
)

var reconnectLogLines = []string{"PollNetMap: EOF", "netmap: got new dial plan from control"}

// nodeLog is a line the running Tailscale server logs through the hook the
// node gave it.
func (tn *fakeTailnet) nodeLog(format string, args ...any) {
	tn.t.Helper()
	tn.mu.Lock()
	logf := tn.nodeLogf
	tn.mu.Unlock()
	if logf == nil {
		tn.t.Fatal("the node gave the server no log hook")
	}
	tn.event("log:" + format)
	logf(format, args...)
}

// runReady starts the node and returns once its address answers and its
// session is waiting for the next thing to do.
func (tn *fakeTailnet) runReady() *Node {
	tn.t.Helper()
	tn.setResult(ProbeOK)
	n := tn.run()
	tn.waitState("running")
	tn.settle(reregisterWithin)
	return n
}

// settle presses Try Again and returns when that test is done. The node's
// session takes what reached it in order, so a log line sent before the press
// has been acted on by the time settle returns. A wait the node makes on the
// way is released, and a wait longer than limit fails the test.
func (tn *fakeTailnet) settle(limit time.Duration) {
	tn.t.Helper()
	for {
		done := make(chan error, 1)
		go func() { done <- tn.node.TryAgain(context.Background()) }()
		if tn.settleWait(done, limit) {
			return
		}
		// The node was between two servers, as a restart leaves it until the
		// new one serves. It is waited for on its own flag; the limit is only
		// the hang ceiling.
		stop := time.Now().Add(hangCeiling)
		for !tn.node.serving.Load() {
			if time.Now().After(stop) {
				tn.t.Fatalf("the node never served again; events %v", tn.log())
			}
			time.Sleep(time.Millisecond)
		}
	}
}

// settleWait waits for one press to end, releasing the waits the node makes on
// the way. It reports false when the node was not serving.
func (tn *fakeTailnet) settleWait(done chan error, limit time.Duration) bool {
	tn.t.Helper()
	for {
		select {
		case err := <-done:
			if errors.Is(err, ErrNotServing) {
				return false
			}
			if err != nil {
				tn.t.Fatalf("TryAgain: %v; events %v", err, tn.log())
			}
			return true
		case d := <-tn.sleeping:
			if d > limit {
				tn.t.Fatalf("the node waited %v, want at most %v; events %v", d, limit, tn.log())
			}
			tn.letGo()
		case <-time.After(hangCeiling):
			tn.t.Fatalf("TryAgain never returned; events %v", tn.log())
		}
	}
}

// count is how many events begin with prefix.
func (tn *fakeTailnet) count(prefix string) int {
	n := 0
	for _, e := range tn.log() {
		if strings.HasPrefix(e, prefix) {
			n++
		}
	}
	return n
}

func (tn *fakeTailnet) offs() []time.Time {
	tn.mu.Lock()
	defer tn.mu.Unlock()
	return slices.Clone(tn.offTimes)
}

// TestNodeTestsAtOnceWhenTheControlSessionReturns protects the address from
// an outage the app would cause itself: when the node's own log says its
// control session ended or came back, a serving node tests the public address
// at once, within ten seconds, and leaves Funnel's registration alone while
// the test answers. It never closes the listener or restarts. The reconnect is
// also counted for diagnostics.
func TestNodeTestsAtOnceWhenTheControlSessionReturns(t *testing.T) {
	for _, line := range reconnectLogLines {
		t.Run(line, func(t *testing.T) {
			tn := newFakeTailnet(t)
			n := tn.runReady()
			at := len(tn.log())
			t0 := tn.clock.Now()
			tn.nodeLog(line)
			tn.settle(reregisterWithin)
			evs := tn.log()[at:]
			if tn.count("funnel-") != 0 {
				t.Errorf("Funnel was switched for a reconnect whose test answered: %v", evs)
			}
			probes := 0
			for i, e := range evs {
				if e != "probe" {
					continue
				}
				probes++
				if probes == 1 {
					for _, before := range evs[:i] {
						if strings.HasPrefix(before, "sleep:") {
							t.Errorf("a wait before the test after the reconnect: %v", evs)
						}
					}
				}
			}
			if probes != 2 {
				t.Errorf("%d public tests, want 2: one at once and the one the press made; %v", probes, evs)
			}
			if waited := tn.clock.Now().Sub(t0); waited > reregisterWithin {
				t.Errorf("tested %v after the line, want within %v", waited, reregisterWithin)
			}
			if tn.count("start#") != 1 || tn.count("close#") != 0 || tn.count("listen-ok#") != 1 {
				t.Errorf("the reconnect restarted the node or reopened the listener: %v", tn.log())
			}
			if got := n.mon.Counts()["control_reconnect"]; got != 1 {
				t.Errorf("control_reconnect = %d, want 1", got)
			}
			m, _ := statusJSON(t, n)
			if counts, _ := m["ts_counts"].(map[string]any); counts["control_reconnect"] != float64(1) {
				t.Errorf("ts_counts = %v, want control_reconnect 1", m["ts_counts"])
			}
			if m["ts_state"] != "running" {
				t.Errorf("ts_state = %v after the reconnect, want running", m["ts_state"])
			}
		})
	}
}

// TestNodeReRegistersAfterAReconnectWhoseTestFailed protects the repair a
// person cannot make: when the test made after a reconnect fails, a serving
// node switches Funnel's registration off and on in its serve config, without
// closing the listener or restarting, and tests the public address again at
// once, before any wait of the ladder's schedule and within ten seconds.
func TestNodeReRegistersAfterAReconnectWhoseTestFailed(t *testing.T) {
	for _, line := range reconnectLogLines {
		t.Run(line, func(t *testing.T) {
			tn := newFakeTailnet(t)
			tn.runReady()
			tn.setResult(ProbeRouteDropped)
			at := len(tn.log())
			t0 := tn.clock.Now()
			tn.nodeLog(line)
			tn.settle(reregisterGap)
			evs := tn.log()[at:]
			start := slices.Index(evs, "log:"+line)
			if start < 0 || len(evs) < start+5 {
				t.Fatalf("too few events after the line: %v", evs)
			}
			if got, want := evs[start+1:start+5], []string{"probe", "funnel-off#1", "funnel-on#1", "probe"}; !slices.Equal(got, want) {
				t.Errorf("after the line: %v, want %v: a failed test, off and on, then a test at once with no wait", got, want)
			}
			if got := len(tn.offs()); got != 1 {
				t.Errorf("%d toggles for a reconnect whose test failed, want 1", got)
			}
			if waited := tn.clock.Now().Sub(t0); waited > reregisterGap {
				t.Errorf("re-registered %v after the line, want within the first window", waited)
			}
			if tn.count("start#") != 1 || tn.count("close#") != 0 || tn.count("listen-ok#") != 1 {
				t.Errorf("the toggle restarted the node or reopened the listener: %v", tn.log())
			}
		})
	}
}

// TestNodeReadsReconnectsFromTheFormatOnly protects what the node logs may
// carry: a line is a reconnect by its format string, as the other counted
// lines are, and never by the text it was formatted into, which can hold an
// address or a peer. The last step shows the real format still acts, so the
// first two are not passing because nothing is wired.
func TestNodeReadsReconnectsFromTheFormatOnly(t *testing.T) {
	tn := newFakeTailnet(t)
	n := tn.runReady()
	tn.nodeLog("relay said: %s", "PollNetMap: EOF")
	tn.nodeLog("%s", "netmap: got new dial plan from control")
	tn.settle(reregisterWithin)
	if got := n.mon.Counts()["control_reconnect"]; got != 0 || tn.count("funnel-") != 0 {
		t.Fatalf("text inside an argument counted as a reconnect: count %d, events %v", got, tn.log())
	}
	// The real line is counted, and with a failing address it also moves Funnel.
	tn.setResult(ProbeRouteDropped)
	tn.nodeLog("PollNetMap: EOF")
	tn.settle(reregisterGap)
	if got := n.mon.Counts()["control_reconnect"]; got != 1 || tn.count("funnel-off") != 1 {
		t.Errorf("the real line: count %d, events %v, want 1 and one toggle", got, tn.log())
	}
}

// TestNodeReRegistersAtMostOncePerThirtySeconds protects the control server
// and the node from a connection that keeps dropping while the address fails:
// a burst of reconnect lines never moves Funnel more than once in thirty
// seconds, and a reconnect after the window is acted on again.
func TestNodeReRegistersAtMostOncePerThirtySeconds(t *testing.T) {
	tn := newFakeTailnet(t)
	tn.runReady()
	tn.setResult(ProbeRouteDropped)
	tn.nodeLog(reconnectLogLines[0])
	tn.settle(reregisterGap)
	if got := len(tn.offs()); got != 1 {
		t.Fatalf("%d toggles for one reconnect, want 1", got)
	}
	for i := 0; i < 60; i++ {
		tn.nodeLog(reconnectLogLines[i%2])
	}
	tn.settle(reregisterGap)
	spaced := func() {
		t.Helper()
		offs := tn.offs()
		for i := 1; i < len(offs); i++ {
			if gap := offs[i].Sub(offs[i-1]); gap < reregisterGap {
				t.Errorf("toggles %d and %d are %v apart, want at least %v", i, i+1, gap, reregisterGap)
			}
		}
	}
	spaced()
	during := len(tn.offs())
	if during > 3 {
		t.Fatalf("%d toggles for a burst of lines, want at most one per thirty seconds", during)
	}
	tn.clock.advance(reregisterGap + time.Second)
	tn.nodeLog(reconnectLogLines[0])
	tn.settle(reregisterGap)
	if got := len(tn.offs()); got < during+1 {
		t.Errorf("%d toggles after a reconnect past the window, want at least %d", got, during+1)
	}
	spaced()
}

// TestNodeFirstFailedTestReRegistersBeforeTheLadder protects the quick repair
// of a registration the servers lost with no log line to say so: the first
// public test of a run that fails has Funnel switched off and on once, after
// the failed test and before the ladder's first reopen; the later failures of
// the run do not toggle again, and the ladder then reopens the listener.
func TestNodeFirstFailedTestReRegistersBeforeTheLadder(t *testing.T) {
	tn := newFakeTailnet(t)
	tn.runReady()
	tn.setResult(ProbeRouteDropped)
	at := len(tn.log())
	tn.settle(reregisterWithin)
	evs := tn.log()[at:]
	probe, off, on := slices.Index(evs, "probe"), slices.Index(evs, "funnel-off#1"), slices.Index(evs, "funnel-on#1")
	if probe < 0 || off < probe || on < off {
		t.Fatalf("after the first failed test the order was %v, want the test, then Funnel off, then on", evs)
	}
	if tn.count("listen-ok#") != 1 || tn.count("start#") != 1 {
		t.Errorf("the first failure reopened or restarted: %v", tn.log())
	}
	for i := 0; i < 2; i++ {
		tn.clock.advance(reregisterGap + time.Second)
		tn.settle(reregisterWithin)
	}
	if got := len(tn.offs()); got != 1 {
		t.Errorf("%d toggles over three failed tests of one run, want 1", got)
	}
	if tn.count("listen-ok#") != 1 {
		t.Errorf("the ladder reopened before the run was four minutes old: %v", tn.log())
	}
	tn.clock.advance(4 * time.Minute)
	tn.settle(reregisterWithin)
	if tn.count("listen-ok#") != 2 {
		t.Errorf("the ladder did not reopen the listener once the address stopped answering: %v", tn.log())
	}
	if got := len(tn.offs()); got != 1 {
		t.Errorf("%d toggles by the time the ladder acted, want 1", got)
	}
}

// TestNodeReconnectTestFeedsTheMonitor protects the backstop when a
// re-registration does not help: the tests made after a reconnect are counted
// and judged like any other, and a reconnect followed by a first failure in
// the same instant moves Funnel once.
func TestNodeReconnectTestFeedsTheMonitor(t *testing.T) {
	tn := newFakeTailnet(t)
	n := tn.runReady()
	tn.setResult(ProbeRouteDropped)
	tn.nodeLog(reconnectLogLines[1])
	tn.settle(reregisterGap)
	if got := len(tn.offs()); got != 1 {
		t.Errorf("%d toggles for a reconnect whose test failed, want 1", got)
	}
	if got := n.mon.Counts()[ProbeRouteDropped.String()]; got < 3 {
		t.Errorf("%d failed tests counted, want at least 3: the one after the reconnect, the one after the toggle and the press", got)
	}
}

// ---- Connection limits on the public address, through the node ----

// feedListener is a public listener whose connections the test hands over in
// order; accepting is closed when the server first asks it for one.
type feedListener struct {
	conns     chan net.Conn
	done      chan struct{}
	once      sync.Once
	accepting chan struct{}
	askOnce   sync.Once
}

func newFeedListener() *feedListener {
	return &feedListener{conns: make(chan net.Conn, 256), done: make(chan struct{}), accepting: make(chan struct{})}
}

func (l *feedListener) Accept() (net.Conn, error) {
	l.askOnce.Do(func() { close(l.accepting) })
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}
func (l *feedListener) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *feedListener) Addr() net.Addr { return &net.TCPAddr{} }

// relayConn reports the Funnel relay as its RemoteAddr, as every Funnel
// connection does.
type relayConn struct{ net.Conn }

func (relayConn) RemoteAddr() net.Addr {
	return net.TCPAddrFromAddrPort(netip.MustParseAddrPort("100.64.0.9:443"))
}

type noReadings struct{}

func (noReadings) Range(context.Context, store.RangeQuery) ([]cgm.Reading, error) { return nil, nil }

// funnelFrom hands the feed a Funnel connection from src and returns the
// client's end of it.
func (l *feedListener) funnelFrom(src string) net.Conn {
	s, c := net.Pipe()
	l.conns <- &ipn.FunnelConn{Conn: relayConn{s}, Src: netip.MustParseAddrPort(src)}
	return c
}

// answer sends a request on c and reads the response; it returns the status,
// or an error when the connection ends without one.
func answer(c net.Conn, br *bufio.Reader, target string) (int, error) {
	go io.WriteString(c, "GET "+target+" HTTP/1.1\r\nHost: relay.example-tailnet.ts.net\r\n\r\n")
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		return 0, err
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return resp.StatusCode, nil
}

// TestPublicListenerThroughTheNode protects the public address against one
// sender holding it. It serves the node's real public server on a listener
// that hands over Funnel connections from chosen senders, all arriving
// through one relay RemoteAddr, and checks what open() built: the idle
// timeout is 10 s with header read 5 s and read and write 10 s untouched (a
// timeout that must be observed is asserted as the server's field; the
// duration itself is the net/http server's), and with sender A holding its 8
// idle connections a ninth from A is closed unserved, a follower request from
// sender B and the app's own public self-test (sender C, the Mac's address)
// are both answered, a closed connection of A frees its slot, and the
// listener keeps serving throughout. Breaks it fails: 60 s idle on the public
// server, any Funnel client counted as the relay (B or C refused), a port in
// the key, a refusal that stops Serve, a slot never freed, and an
// unconfigured per-sender cap (the ninth served).
func TestPublicListenerThroughTheNode(t *testing.T) {
	const token = "public-token"
	ns, err := nightscout.New(noReadings{}, token, nil)
	if err != nil {
		t.Fatal(err)
	}
	feed := newFeedListener()
	var built atomic.Pointer[http.Server]
	tn := newFakeTailnet(t)
	tn.ln = feed
	tn.handler = ns
	tn.newServer = func(h http.Handler) *http.Server {
		srv := &http.Server{
			Handler: h, ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
		}
		built.Store(srv)
		return srv
	}
	tn.run()
	select {
	case <-feed.accepting:
	case <-time.After(hangCeiling):
		t.Fatalf("the public server never started serving; events %v", tn.log())
	}
	srv := built.Load()
	if srv.IdleTimeout != 10*time.Second {
		t.Errorf("public IdleTimeout = %v, want 10s", srv.IdleTimeout)
	}
	if srv.ReadHeaderTimeout != 5*time.Second || srv.ReadTimeout != 10*time.Second || srv.WriteTimeout != 10*time.Second {
		t.Errorf("public header %v read %v write %v, want 5s 10s 10s", srv.ReadHeaderTimeout, srv.ReadTimeout, srv.WriteTimeout)
	}

	// Sender A holds its 8 connections, each from its own port, idle.
	var idle []net.Conn
	for i := 0; i < MaxConnsPerSender; i++ {
		idle = append(idle, feed.funnelFrom(fmt.Sprintf("203.0.113.5:%d", 40000+i)))
	}
	ninth := feed.funnelFrom("203.0.113.5:50000")
	if _, err := answer(ninth, bufio.NewReader(ninth), "/"); err == nil {
		t.Error("a ninth connection from one sender was served")
	} else if !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.ErrClosedPipe) {
		// http.ReadResponse reports a connection closed before the status line
		// as io.ErrUnexpectedEOF, so that is what a refused connection reads as.
		t.Errorf("ninth connection: %v, want it closed", err)
	}

	// The flood holds; another sender's follower request and the app's own
	// public self-test are both answered.
	follower := feed.funnelFrom("198.51.100.20:1234")
	if code, err := answer(follower, bufio.NewReader(follower), "/api/v1/entries.json?token="+token); err != nil || code != 200 {
		t.Errorf("follower request from another sender while A holds 8: %d, %v; want 200", code, err)
	}
	self := feed.funnelFrom("192.0.2.77:9999")
	if code, err := answer(self, bufio.NewReader(self), "/api/v1/status.json"); err != nil || code != 200 {
		t.Errorf("self-test while A holds 8: %d, %v; want 200", code, err)
	}

	// A's closed connection frees its slot. The server notices the close
	// asynchronously, so a connection that arrives before that is refused
	// like any other; each refusal is itself an answer, and the loop ends at
	// the first success, or fails when no slot ever frees.
	idle[0].Close()
	freed := false
	for attempt := 0; attempt < 100000 && !freed; attempt++ {
		c := feed.funnelFrom(fmt.Sprintf("203.0.113.5:%d", 51000+attempt%10000))
		code, err := answer(c, bufio.NewReader(c), "/")
		freed = err == nil && code == 200
		c.Close()
	}
	if !freed {
		t.Error("after one of sender A's connections closed, no new connection from A was ever served: its slot was never freed")
	}
}

// plantKey puts a file standing for the node key into the state folder and
// returns its path.
func (tn *fakeTailnet) plantKey() string {
	tn.t.Helper()
	p := filepath.Join(tn.dir, "tailscaled.state")
	if err := os.WriteFile(p, []byte("node-key"), 0o600); err != nil {
		tn.t.Fatalf("plant the key: %v", err)
	}
	return p
}

func (tn *fakeTailnet) failLogout(err error) {
	tn.mu.Lock()
	tn.logoutErr = err
	tn.mu.Unlock()
}

// requireKeptState fails unless the state folder and the key file in it are
// as plantKey left them.
func requireKeptState(t *testing.T, tn *fakeTailnet, key, when string) {
	t.Helper()
	if got, err := os.ReadFile(key); err != nil || string(got) != "node-key" {
		t.Errorf("%s: the key file is %q, %v; want it kept unchanged", when, got, err)
	}
	if fi, err := os.Stat(tn.dir); err != nil || !fi.IsDir() {
		t.Errorf("%s: the state folder is gone: %v", when, err)
	}
}

// TestLeaveTailnetLogsOutBeforeTheNodeStopsAndRemovesTheFolder protects the
// person's Tailscale account from a machine that still holds a working key:
// leaving the built-in route tells the control server first, and only then
// lets the node stop, and once that has succeeded the folder that held the
// node key is gone. A node that stopped before logging out, never logged out,
// or left the folder behind fails it.
func TestLeaveTailnetLogsOutBeforeTheNodeStopsAndRemovesTheFolder(t *testing.T) {
	tn := newFakeTailnet(t)
	n := tn.runReady()
	key := tn.plantKey()

	res, err := n.LeaveTailnet(context.Background())
	if err != nil || res != LeftAndRemoved {
		t.Fatalf("LeaveTailnet = %v, %v; want LeftAndRemoved and no error", res, err)
	}
	evs := tn.log()
	if tn.count("logout#") != 1 {
		t.Fatalf("the node logged out %d times, want once: %v", tn.count("logout#"), evs)
	}
	done := slices.Index(evs, "logout-done#1")
	if done < 0 {
		t.Fatalf("logout never returned before LeaveTailnet did: %v", evs)
	}
	if cl := slices.Index(evs, "close#1"); cl >= 0 && cl < done {
		t.Errorf("the node was closed before the logout finished: %v", evs)
	}
	if _, err := os.Stat(key); !os.IsNotExist(err) {
		t.Errorf("the key file is still there after a successful logout: %v", err)
	}
	if _, err := os.Stat(tn.dir); !os.IsNotExist(err) {
		t.Errorf("the state folder is still there after a successful logout: %v", err)
	}
	if tn.startCount() != 1 {
		t.Errorf("leaving started a node again: %v", evs)
	}
}

// TestLeaveTailnetThatFailsKeepsTheFolderAndTheKey protects the only way to
// log the machine out later: a logout that did not reach the control server
// (the Mac is offline) must leave the key where it is, and say so, so the
// next launch can try again. A folder deleted anyway, or a failure reported as
// a success, fails it.
func TestLeaveTailnetThatFailsKeepsTheFolderAndTheKey(t *testing.T) {
	tn := newFakeTailnet(t)
	n := tn.runReady()
	key := tn.plantKey()
	tn.failLogout(errors.New("control server unreachable"))

	res, _ := n.LeaveTailnet(context.Background())
	if res != KeptForRetry {
		t.Errorf("a failed logout answered %v, want KeptForRetry", res)
	}
	if tn.count("logout#") != 1 {
		t.Errorf("the node tried to log out %d times, want once: %v", tn.count("logout#"), tn.log())
	}
	requireKeptState(t, tn, key, "after a failed logout")
}

// TestLeaveTailnetThatNeverAnswersKeepsTheFolderAndTheKey is the offline Mac
// whose logout hangs: when the call ends without an answer (here, the caller's
// context ends once the node is waiting on the control server) the result is
// the same as a failure, and nothing is deleted.
func TestLeaveTailnetThatNeverAnswersKeepsTheFolderAndTheKey(t *testing.T) {
	tn := newFakeTailnet(t)
	n := tn.runReady()
	key := tn.plantKey()
	tn.mu.Lock()
	tn.logoutHangs = true
	tn.mu.Unlock()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	got := make(chan LeaveResult, 1)
	go func() {
		res, _ := n.LeaveTailnet(ctx)
		got <- res
	}()
	tn.waitForEvent("logout#")
	cancel()
	select {
	case res := <-got:
		if res != KeptForRetry {
			t.Errorf("a logout that never answered gave %v, want KeptForRetry", res)
		}
	case <-time.After(hangCeiling):
		t.Fatalf("LeaveTailnet never returned after its context ended; events %v", tn.log())
	}
	requireKeptState(t, tn, key, "after a logout that never answered")
}

// TestFailedLeaveIsRetriedOnTheNextLaunch protects the retry: after a failed
// logout and a quit, a new node started on the kept folder can leave, and then
// the folder is gone. The first node's end never logs out on its own.
func TestFailedLeaveIsRetriedOnTheNextLaunch(t *testing.T) {
	first := newFakeTailnet(t)
	n := first.runReady()
	key := first.plantKey()
	first.failLogout(errors.New("control server unreachable"))
	if res, _ := n.LeaveTailnet(context.Background()); res != KeptForRetry {
		t.Fatalf("the first leave answered %v, so the check cannot tell", res)
	}
	n.Close()
	requireKeptState(t, first, key, "after the quit that followed the failed leave")
	if first.count("logout#") != 1 {
		t.Errorf("the quit logged out again: %v", first.log())
	}

	second := newFakeTailnet(t)
	second.dir = first.dir
	n2 := second.runReady()
	res, err := n2.LeaveTailnet(context.Background())
	if err != nil || res != LeftAndRemoved {
		t.Errorf("the retry = %v, %v; want LeftAndRemoved and no error", res, err)
	}
	if _, err := os.Stat(first.dir); !os.IsNotExist(err) {
		t.Errorf("the state folder is still there after the retry succeeded: %v", err)
	}
}

// TestNoRestartPathLogsOut protects the node key and the public address from
// every restart the engine makes: a restart, the repair ladder's restarts and
// the end of the node all keep the folder and its key, hand the same folder to
// the next server, and never log out. Only LeaveTailnet logs out.
func TestNoRestartPathLogsOut(t *testing.T) {
	t.Run("Restart", func(t *testing.T) {
		tn := newFakeTailnet(t)
		n := tn.runReady()
		key := tn.plantKey()
		if err := n.Restart(context.Background()); err != nil {
			t.Fatalf("Restart: %v", err)
		}
		tn.settle(time.Hour)
		if tn.startCount() != 2 {
			t.Fatalf("starts = %d, want 2, so the check cannot tell: %v", tn.startCount(), tn.log())
		}
		if tn.count("logout") != 0 {
			t.Errorf("a restart logged out: %v", tn.log())
		}
		requireKeptState(t, tn, key, "after a restart")
		tn.requireOneFolder()
	})
	t.Run("repair ladder", func(t *testing.T) {
		tn := newFakeTailnet(t)
		tn.runReady()
		key := tn.plantKey()
		for i := 0; i < 2; i++ {
			tn.clock.advance(5 * time.Minute)
			tn.settle(time.Hour)
		}
		tn.setResult(ProbeRouteDropped)
		for i := 0; i < 40 && tn.startCount() < 3; i++ {
			tn.clock.advance(time.Minute)
			tn.settle(time.Hour)
		}
		if tn.startCount() < 2 {
			t.Fatalf("the ladder never restarted the node, so the check cannot tell: %v", tn.log())
		}
		if tn.count("logout") != 0 {
			t.Errorf("a repair restart logged out: %v", tn.log())
		}
		requireKeptState(t, tn, key, "after the repair restarts")
		tn.requireOneFolder()
	})
	t.Run("Close", func(t *testing.T) {
		tn := newFakeTailnet(t)
		n := tn.runReady()
		key := tn.plantKey()
		n.Close()
		if tn.count("close#") == 0 {
			t.Fatalf("Close never closed the node, so the check cannot tell: %v", tn.log())
		}
		if tn.count("logout") != 0 {
			t.Errorf("Close logged out: %v", tn.log())
		}
		requireKeptState(t, tn, key, "after Close")
	})
}

// requireOneFolder fails unless every start of the node was on the one state
// folder of the test.
func (tn *fakeTailnet) requireOneFolder() {
	tn.t.Helper()
	tn.mu.Lock()
	starts := slices.Clone(tn.starts)
	tn.mu.Unlock()
	for _, s := range starts {
		if s.dir != tn.dir {
			tn.t.Errorf("a server was started on %s, want the folder %s every time", s.dir, tn.dir)
		}
	}
}

// TestPrepareStateDirExcludesTheFolderFromBackups protects the node key from
// ending up in a Time Machine backup: whenever the folder is created, the
// extended attribute that excludes it is set, and a folder created again after
// a leave gets it again. Both sides of the app create this folder, so the
// engine's own creation is checked here.
func TestPrepareStateDirExcludesTheFolderFromBackups(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("backup exclusion by extended attribute is a macOS feature")
	}
	const attr = "com.apple.metadata:com_apple_backup_excludeItem"
	dir := filepath.Join(t.TempDir(), "ts")
	excluded := func(when string) {
		t.Helper()
		sz, err := unix.Getxattr(dir, attr, nil)
		if err != nil || sz <= 0 {
			t.Errorf("%s: the backup exclusion attribute is not set on the folder (%d, %v)", when, sz, err)
		}
	}
	if err := prepareStateDir(dir); err != nil {
		t.Fatalf("prepareStateDir: %v", err)
	}
	excluded("a fresh folder")
	if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("state folder %v, %v; want mode 0700", fi, err)
	}
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if err := prepareStateDir(dir); err != nil {
		t.Fatalf("prepareStateDir again: %v", err)
	}
	excluded("a folder created again after being removed")
}

// leaveRig is Tailscale's own fake control server (testcontrol) with a local
// DERP relay, a hook that records every register request the way a logout
// shows itself to a control server (a register request for a node key whose
// expiry is already past), and a switch that takes the control server away
// and brings it back on the same address. Nothing leaves loopback.
type leaveRig struct {
	t    *testing.T
	ctrl *testcontrol.Server
	addr string

	mu       sync.Mutex
	hs       *httptest.Server
	requests int              // every machine request the control server saw
	logins   []key.NodePublic // node keys registered without an expiry
	logouts  []key.NodePublic // node keys registered with an expiry already past
	contacts int              // register requests of any kind
}

func newLeaveRig(t *testing.T) *leaveRig {
	t.Helper()
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	r := &leaveRig{t: t}
	r.ctrl = &testcontrol.Server{
		DNSConfig:      &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain: "tail-scale.ts.net",
		RequireAuth:    false,
		MaybeRejectRequest: func(req *http.Request) (int, string, string) {
			r.observe(req)
			return 0, "", ""
		},
	}
	r.up()
	t.Cleanup(r.down)
	return r
}

func (r *leaveRig) observe(req *http.Request) {
	r.mu.Lock()
	r.requests++
	r.mu.Unlock()
	if req.URL.Path != "/machine/register" || req.Body == nil {
		return
	}
	body, err := io.ReadAll(req.Body)
	req.Body = io.NopCloser(strings.NewReader(string(body)))
	if err != nil {
		return
	}
	var rr tailcfg.RegisterRequest
	if json.Unmarshal(body, &rr) != nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.contacts++
	if !rr.Expiry.IsZero() && rr.Expiry.Before(time.Now()) {
		r.logouts = append(r.logouts, rr.NodeKey)
	} else if !slices.Contains(r.logins, rr.NodeKey) {
		r.logins = append(r.logins, rr.NodeKey)
	}
}

// up starts serving the control server, on the address it first had when it
// has been up before.
func (r *leaveRig) up() {
	r.t.Helper()
	listen := "127.0.0.1:0"
	if r.addr != "" {
		listen = r.addr
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		r.t.Fatalf("control server cannot listen on %s: %v", listen, err)
	}
	hs := httptest.NewUnstartedServer(r.ctrl)
	hs.Listener.Close()
	hs.Listener = ln
	hs.Start()
	r.ctrl.HTTPTestServer = hs
	r.mu.Lock()
	r.hs = hs
	r.addr = ln.Addr().String()
	r.mu.Unlock()
}

// down takes the control server away: connections are refused until up.
func (r *leaveRig) down() {
	r.mu.Lock()
	hs := r.hs
	r.hs = nil
	r.mu.Unlock()
	if hs != nil {
		hs.CloseClientConnections()
		hs.Close()
	}
}

func (r *leaveRig) url() string { return "http://" + r.addr }

func (r *leaveRig) loggedOut() []key.NodePublic {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.logouts)
}

func (r *leaveRig) registered() []key.NodePublic {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.logins)
}

func (r *leaveRig) registerRequests() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.contacts
}

// loginNode brings a real tsnet node up, signed in to the fake control server
// on dir, then closes it: what is left is the folder a built-in route leaves
// behind. It returns the node key the control server registered.
func (r *leaveRig) loginNode(dir string) key.NodePublic {
	r.t.Helper()
	before := len(r.registered())
	s := &tsnet.Server{Dir: dir, Hostname: "relay-test", ControlURL: r.url(), Logf: logger.Discard, UserLogf: logger.Discard}
	ctx, cancel := context.WithTimeout(context.Background(), hangCeiling)
	defer cancel()
	if err := waitSignedIn(ctx, s); err != nil {
		_ = s.Close()
		r.t.Fatalf("the node never signed in to the fake control server: %v", err)
	}
	if err := s.Close(); err != nil {
		r.t.Fatalf("closing the signed-in node: %v", err)
	}
	logins := r.registered()
	if len(logins) != before+1 {
		r.t.Fatalf("the control server registered %d node keys for the sign-in, want 1", len(logins)-before)
	}
	return logins[len(logins)-1]
}

// waitSignedIn returns once the node has been accepted by the control server
// and has its first network map, the point from which it holds a working node
// key. The fake control server has no relay, so the node never reaches
// Running; Starting is as far as it goes.
func waitSignedIn(ctx context.Context, s *tsnet.Server) error {
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	w, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		return err
	}
	defer w.Close()
	for {
		n, err := w.Next()
		if err != nil {
			return err
		}
		if st := n.State; st != nil && (*st == ipn.Starting || *st == ipn.Running) {
			return nil
		}
	}
}

// leaveWithin runs LeaveKeptFolder under a context that ends after limit and
// fails the test if it has not returned long after that, the hang ceiling.
func leaveWithin(t *testing.T, limit time.Duration, dir string) (LeaveResult, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	type answer struct {
		res LeaveResult
		err error
	}
	got := make(chan answer, 1)
	go func() {
		res, err := LeaveKeptFolder(ctx, dir, "relay-test")
		got <- answer{res, err}
	}()
	select {
	case a := <-got:
		return a.res, a.err
	case <-time.After(hangCeiling):
		t.Fatalf("LeaveKeptFolder did not return, and its context ended after %v", limit)
		return KeptForRetry, nil
	}
}

// requireKeyKept fails unless dir and a non-empty node state file are still there.
func requireKeyKept(t *testing.T, dir, when string) {
	t.Helper()
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		t.Fatalf("%s: the state folder is gone: %v", when, err)
	}
	state, err := os.ReadFile(filepath.Join(dir, "tailscaled.state"))
	if err != nil || len(state) == 0 {
		t.Errorf("%s: the node's state file (with its key) is missing or empty: %v", when, err)
	}
}

// TestLeaveKeptFolderLogsOutAndRemovesTheFolder protects the person's
// Tailscale account when the engine cannot run (no LibreLinkUp sign-in) but a
// failed leave left a folder with a working node key: leaving it starts a node
// on that folder only to log it out, the control server is told for that very
// key, and the folder is gone. A folder removed without telling the control
// server, a logout for another key, or a folder left behind fails it.
func TestLeaveKeptFolderLogsOutAndRemovesTheFolder(t *testing.T) {
	r := newLeaveRig(t)
	t.Setenv("TS_CONTROL_URL", r.url())
	dir := filepath.Join(t.TempDir(), "ts")
	nodeKey := r.loginNode(dir)
	requireKeyKept(t, dir, "after the sign-in")

	res, err := leaveWithin(t, hangCeiling, dir)
	if err != nil || res != LeftAndRemoved {
		t.Fatalf("LeaveKeptFolder = %v, %v; want LeftAndRemoved and no error", res, err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("the state folder is still there after the logout answered: %v", err)
	}
	if out := r.loggedOut(); !slices.Equal(out, []key.NodePublic{nodeKey}) {
		t.Errorf("the control server saw logouts for %v, want exactly one, for the node key it registered (%v)", out, nodeKey)
	}
}

// TestLeaveKeptFolderThatCannotReachControlKeepsTheFolderAndKey protects the
// only way to log the machine out later: a logout that cannot reach Tailscale
// (the Mac is offline, or the control server takes the connection and never
// answers) ends by the caller's deadline with KeptForRetry, the folder and key
// untouched. A folder deleted anyway, a success reported, or a call that
// outlives its context fails it.
func TestLeaveKeptFolderThatCannotReachControlKeepsTheFolderAndKey(t *testing.T) {
	t.Run("connection refused", func(t *testing.T) {
		r := newLeaveRig(t)
		t.Setenv("TS_CONTROL_URL", r.url())
		dir := filepath.Join(t.TempDir(), "ts")
		r.loginNode(dir)
		before, err := os.ReadFile(filepath.Join(dir, "tailscaled.state"))
		if err != nil {
			t.Fatalf("the signed-in folder has no state file: %v", err)
		}
		r.down()

		res, _ := leaveWithin(t, 20*time.Second, dir)
		if res != KeptForRetry {
			t.Errorf("a logout that could not reach control answered %v, want KeptForRetry", res)
		}
		requireKeyKept(t, dir, "after a logout that could not connect")
		if got, _ := os.ReadFile(filepath.Join(dir, "tailscaled.state")); len(got) == 0 || len(before) == 0 {
			t.Errorf("the node state file was emptied")
		}
	})
	t.Run("connection taken and never answered", func(t *testing.T) {
		r := newLeaveRig(t)
		t.Setenv("TS_CONTROL_URL", r.url())
		dir := filepath.Join(t.TempDir(), "ts")
		r.loginNode(dir)
		r.down()

		// A listener that accepts and says nothing, in the control server's place.
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		var held []net.Conn
		var heldMu sync.Mutex
		go func() {
			for {
				c, err := ln.Accept()
				if err != nil {
					return
				}
				heldMu.Lock()
				held = append(held, c)
				heldMu.Unlock()
			}
		}()
		t.Cleanup(func() {
			ln.Close()
			heldMu.Lock()
			for _, c := range held {
				c.Close()
			}
			heldMu.Unlock()
		})
		t.Setenv("TS_CONTROL_URL", "http://"+ln.Addr().String())

		res, _ := leaveWithin(t, 5*time.Second, dir)
		if res != KeptForRetry {
			t.Errorf("a logout that never answered gave %v, want KeptForRetry", res)
		}
		requireKeyKept(t, dir, "after a logout that never answered")
	})
}

// TestLeaveKeptFolderRetriesOnTheSameKeyOnceControlIsBack protects the retry:
// after a failed logout the same folder still holds the same node key, so the
// next attempt, with the control server reachable again, logs that very key
// out and removes the folder.
func TestLeaveKeptFolderRetriesOnTheSameKeyOnceControlIsBack(t *testing.T) {
	r := newLeaveRig(t)
	t.Setenv("TS_CONTROL_URL", r.url())
	dir := filepath.Join(t.TempDir(), "ts")
	nodeKey := r.loginNode(dir)
	r.down()

	if res, _ := leaveWithin(t, 20*time.Second, dir); res != KeptForRetry {
		t.Fatalf("the first leave answered %v with control away, so the retry cannot be told", res)
	}
	requireKeyKept(t, dir, "after the failed leave")
	if out := r.loggedOut(); len(out) != 0 {
		t.Fatalf("a logout reached the control server while it was away: %v", out)
	}

	r.up()
	res, err := leaveWithin(t, hangCeiling, dir)
	if err != nil || res != LeftAndRemoved {
		t.Fatalf("the retry = %v, %v; want LeftAndRemoved and no error", res, err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("the state folder is still there after the retry succeeded: %v", err)
	}
	if out := r.loggedOut(); !slices.Equal(out, []key.NodePublic{nodeKey}) {
		t.Errorf("the retry logged out %v, want the node key the folder held from the start (%v)", out, nodeKey)
	}
}

// TestLeaveKeptFolderOnAFolderThatNeverSignedInStartsNoSignIn protects the
// person from a sign-in page they never asked for: leaving a folder whose node
// is not logged in (no node key in its saved state) must not ask the control
// server for a sign-in address, must not hang, and answers LeftAndRemoved with
// the folder gone, since there is no key to log out and a kept folder would
// leave the retry pending forever. The control server here requires a
// sign-in, so any start of one shows as a register request.
func TestLeaveKeptFolderOnAFolderThatNeverSignedInStartsNoSignIn(t *testing.T) {
	r := newLeaveRig(t)
	r.ctrl.RequireAuth = true
	t.Setenv("TS_CONTROL_URL", r.url())
	dir := filepath.Join(t.TempDir(), "ts")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}

	res, err := leaveWithin(t, hangCeiling, dir)
	if err != nil || res != LeftAndRemoved {
		t.Errorf("LeaveKeptFolder = %v, %v; want LeftAndRemoved and no error", res, err)
	}
	if _, statErr := os.Stat(dir); !os.IsNotExist(statErr) {
		t.Errorf("the state folder is still there: %v", statErr)
	}
	if n := r.registerRequests(); n != 0 {
		t.Errorf("the control server saw %d register requests for a node that was never signed in, want none (no sign-in started)", n)
	}
	if out := r.loggedOut(); len(out) != 0 {
		t.Errorf("logouts recorded for a node that never signed in: %v", out)
	}
}
