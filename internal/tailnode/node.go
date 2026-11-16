package tailnode

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/logtail"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
)

// closeTimeout bounds Close as a whole, so the engine can leave inside the
// time the app gives it. The node's own shutdown can take longer when the
// network is gone; Close then returns and the process exit ends it.
const closeTimeout = time.Second

// serverShutdownTimeout bounds how long the public server waits for a
// request in flight once the node is closing.
const serverShutdownTimeout = 300 * time.Millisecond

// publicPort is the port Funnel serves, the only one of its three that
// needs no extra setting.
const publicPort = ":443"

// retry cadence for the steps that wait on a person or on the network.
const (
	retryFirst = 3 * time.Second
	retryMax   = 15 * time.Second
	// settleWait is the least a session waits before its first test after
	// the node came up again, so the test does not run against a node that is
	// still bringing its listener and certificate up.
	settleWait = retryMax
	// publicAttemptTimeout bounds one request to the node's own address.
	publicAttemptTimeout = 20 * time.Second
	// publishFirst and publishMax are the waits between the tests made until
	// the address first answers: a new public name can take minutes to
	// appear, so the tests start quick and settle at a modest rate.
	publishFirst = 5 * time.Second
	publishMax   = 30 * time.Second
	// loginURLGrace is how long a node that needs a sign-in may lack a
	// sign-in page before one is asked for.
	loginURLGrace = 5 * time.Second
)

// publicCheckPath is answered without a token by the relay, and says only
// that it is up.
const publicCheckPath = "/api/v1/status.json"

// ErrNotServing is what TryAgain reports while the public listener is not
// serving, so there is nothing to test.
var ErrNotServing = errors.New("tailnode: the public address is not serving")

// Options configure a Node.
type Options struct {
	// StateDir holds the node's saved sign-in. It is created with mode 0700
	// and must never sit in a place that is committed or shipped.
	StateDir string
	// Hostname is the generic name the node asks for. The public name is
	// derived from the tailnet, never from this value.
	Hostname string
	// Handler is the relay's API handler, which the public listener serves
	// behind PublicHandler.
	Handler http.Handler
	// NewServer builds the HTTP server for the public listener around the
	// handler it is given, so it keeps the relay's own timeouts. The node
	// sets its error log.
	NewServer func(http.Handler) *http.Server
	// Logf, when set, receives one plain line per state change. It never
	// receives a URL, a key or an address.
	Logf func(format string, args ...any)

	// controlURL points the node at another control server. Only an
	// in-package test sets it.
	controlURL string
	// now stands in for time.Now in a test.
	now func() time.Time
	// sleep stands in for the waits between tests, startNode for the real
	// Tailscale server and probe for the public test, in a test.
	sleep     func(ctx context.Context, d time.Duration) bool
	probe     ProbeFunc
	startNode func(dir, hostname string, logf func(string, ...any)) (nodeAPI, error)
}

// nodeAPI is what the node needs of a running Tailscale server.
type nodeAPI interface {
	Status(ctx context.Context) (*ipnstate.Status, error)
	QueryFunnel(ctx context.Context) (*tailcfg.QueryFeatureResponse, error)
	ListenFunnel(ctx context.Context) (net.Listener, error)
	// SetFunnelAllowed turns Funnel's registration off or on in the serve
	// config, leaving the listener as it is. Setting the state the config
	// already has is an error, since control ignores an unchanged config.
	SetFunnelAllowed(ctx context.Context, allowed bool) error
	// WarmCertificate has the node fetch or issue the certificate for host.
	WarmCertificate(ctx context.Context, host string)
	StartLogin(ctx context.Context) error
	// Logout tells the control server this machine leaves the account, which
	// expires its node key. It does not touch the state folder.
	Logout(ctx context.Context) error
	Watch(ctx context.Context) (ipnWatcher, error)
	Close() error
}

type ipnWatcher interface {
	Next() (ipn.Notify, error)
	Close() error
}

// Node is a running built-in Tailscale node.
type Node struct {
	opts   Options
	now    func() time.Time
	cancel context.CancelFunc

	started chan struct{} // closed once Start has returned
	done    chan struct{} // closed when the run goroutine has ended

	mon     *Monitor
	probe   ProbeFunc
	serving atomic.Bool
	tryCh   chan chan struct{} // a pending Try Again, answered when its test is done

	mu       sync.Mutex
	srv      *tsnet.Server // the real server, when there is one
	api      nodeAPI
	obs      Observation
	key      string
	since    time.Time
	prevDone chan struct{} // the previous serving cycle's end
	restart  context.CancelFunc
	nextUp   chan struct{} // closed when the next server has started
	cur      *openListener
	read     *ipnstate.Status // the status the last test read, and its error
	readErr  error
}

// Start begins bringing the node up in the background and returns at once;
// Status reports how far it has got. It never returns nil: a node that
// cannot start reports that as its error state.
func Start(opts Options) *Node {
	n := &Node{
		opts:    opts,
		now:     opts.now,
		started: make(chan struct{}),
		done:    make(chan struct{}),
		tryCh:   make(chan chan struct{}, 1),
		nextUp:  make(chan struct{}),
	}
	if n.now == nil {
		n.now = time.Now
	}
	n.probe = opts.probe
	if n.probe == nil {
		n.probe = NewPublicProbe()
	}
	if n.opts.startNode == nil {
		n.opts.startNode = realStart(opts.controlURL)
	}
	n.mon = NewMonitor(MonitorOptions{Now: n.now, Probe: n.probe, Node: n.nodeCheck, Repair: nodeRepair{n}})
	n.since = n.now()
	ctx, cancel := context.WithCancel(context.Background())
	n.cancel = cancel
	go n.run(ctx)
	return n
}

// Status is the node's current status.
func (n *Node) Status() Status {
	n.mu.Lock()
	changed := n.settleLocked()
	o := n.mon.Apply(n.obs)
	o.InStateFor = n.now().Sub(n.since)
	key := n.key
	s := State(o)
	n.mu.Unlock()
	n.logState(changed, key)
	return s
}

// settleLocked restarts the state's clock when the state has changed, whether
// the observation or the monitor changed it, and reports whether it did.
func (n *Node) settleLocked() bool {
	key := State(n.mon.Apply(n.obs)).State
	if key == n.key {
		return false
	}
	n.key = key
	n.since = n.now()
	return true
}

func (n *Node) logState(changed bool, key string) {
	if changed && n.opts.Logf != nil {
		n.opts.Logf("built-in Tailscale: %s", key)
	}
}

// TryAgain makes a public test at once and takes the next repair step if it
// fails, then returns. While the address is publishing or not reachable the
// press first switches Funnel off and on, within the press limits. It returns ErrNotServing while there is no listener to
// test, and does nothing more when a press is already waiting.
func (n *Node) TryAgain(ctx context.Context) error {
	if !n.serving.Load() {
		return ErrNotServing
	}
	done := make(chan struct{})
	select {
	case n.tryCh <- done:
	default:
		return nil
	}
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-n.done:
		return ErrNotServing
	}
}

// Restart brings the node down and up again on the same state folder, and
// returns once the new server has started or ctx is done. The sign-in and key
// are kept because the folder is. The first failed test after it registers
// Funnel again.
func (n *Node) Restart(ctx context.Context) error {
	n.mu.Lock()
	up := n.nextUp
	n.mu.Unlock()
	n.mon.RecordRestart()
	n.requestRestart()
	select {
	case <-up:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-n.done:
		return errors.New("tailnode: the node has stopped")
	}
}

// requestRestart ends the running server's cycle so run starts a new one. It
// does not wait, since the public test that asks for it runs inside that cycle.
func (n *Node) requestRestart() {
	n.mu.Lock()
	cancel := n.restart
	n.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// nodeCheck is the monitor's read of the node, from the status the session
// read just before the test.
func (n *Node) nodeCheck(context.Context) ProbeClass {
	n.mu.Lock()
	defer n.mu.Unlock()
	return nodeHealth(n.read, n.readErr)
}

// reregisterPause is how long Funnel stays off in a re-registration. The two
// changes of the serve config must reach control one after the other, since
// control is told only of the state the node is in when it sends.
const reregisterPause = 2 * time.Second

// reregister turns Funnel's registration off and on in the serve config, so
// the node tells control afresh that it has Funnel on. The listener is not
// touched, and Funnel is always put back, even when the wait is cut short.
func (n *Node) reregister(ctx context.Context) error {
	return n.reregisterWith(ctx, sleep)
}

// pressReregister is the re-registration a Try Again makes before its test,
// when the press limits allow one, and reports whether it was made. Its pause
// is a plain wait, as every re-registration's is, so the test that follows is
// not held behind the node's scheduled waits.
func (n *Node) pressReregister(ctx context.Context) bool {
	if !n.mon.AllowPress() {
		return false
	}
	_ = n.reregisterWith(ctx, sleep)
	return true
}

// reregisterWith is reregister with the wait between the two changes given.
func (n *Node) reregisterWith(ctx context.Context, pause func(context.Context, time.Duration) bool) error {
	n.mu.Lock()
	api := n.api
	n.mu.Unlock()
	if api == nil {
		return ErrNotServing
	}
	if err := api.SetFunnelAllowed(ctx, false); err != nil {
		return err
	}
	paused := pause(ctx, reregisterPause)
	rctx := ctx
	if !paused {
		var cancel context.CancelFunc
		rctx, cancel = context.WithTimeout(context.WithoutCancel(ctx), serverShutdownTimeout*10)
		defer cancel()
	}
	return api.SetFunnelAllowed(rctx, true)
}

// nodeRepair is the Monitor's way of repairing the node.
type nodeRepair struct{ n *Node }

func (r nodeRepair) ReopenListener(ctx context.Context) error { return r.n.reopen(ctx) }

func (r nodeRepair) ReregisterFunnel(ctx context.Context) error { return r.n.reregister(ctx) }

func (r nodeRepair) RestartNode(context.Context) error {
	r.n.requestRestart()
	return nil
}

// Close stops the node: the public server first, then the tailnet node. It
// returns within closeTimeout whatever the network is doing, and never closes
// the node while Start is still running.
func (n *Node) Close() {
	deadline := time.NewTimer(closeTimeout)
	defer deadline.Stop()
	n.cancel()
	select {
	case <-n.started:
	case <-deadline.C:
		return
	}
	// Give the serving cycle a moment to stop its server; a cycle blocked
	// inside the node is released by closing the node below.
	grace := time.NewTimer(closeTimeout / 2)
	defer grace.Stop()
	select {
	case <-n.done:
	case <-grace.C:
	case <-deadline.C:
		return
	}
	n.mu.Lock()
	api := n.api
	n.mu.Unlock()
	if api != nil {
		closed := make(chan struct{})
		go func() { _ = api.Close(); close(closed) }()
		select {
		case <-closed:
		case <-deadline.C:
			return
		}
	}
	select {
	case <-n.done:
	case <-deadline.C:
	}
}

// LeaveResult is how far LeaveTailnet got.
type LeaveResult int

const (
	// LeftAndRemoved means the control server was told, the node has stopped
	// and the state folder is gone.
	LeftAndRemoved LeaveResult = iota
	// KeptForRetry means the machine may still be on the account: the node and
	// its folder, with the key, are kept so a later launch can leave again.
	KeptForRetry
)

// LeaveTailnet logs the node out of the person's account, then stops it and
// removes its state folder. The node is stopped only after the logout has
// answered, and the folder is removed only after that. A logout that fails or
// is cut short by ctx keeps the folder and the key and answers KeptForRetry.
// Nothing else logs out: Close and every restart keep the key.
func (n *Node) LeaveTailnet(ctx context.Context) (LeaveResult, error) {
	n.mu.Lock()
	api := n.api
	n.mu.Unlock()
	if api == nil {
		return KeptForRetry, ErrNotServing
	}
	if err := api.Logout(ctx); err != nil {
		return KeptForRetry, err
	}
	n.Close()
	if err := os.RemoveAll(n.opts.StateDir); err != nil {
		return KeptForRetry, err
	}
	return LeftAndRemoved, nil
}

// update applies f to the observation and restarts the clock when the state
// it leads to changes.
func (n *Node) update(f func(*Observation)) {
	n.mu.Lock()
	f(&n.obs)
	changed := n.settleLocked()
	key := n.key
	n.mu.Unlock()
	n.logState(changed, key)
}

func (n *Node) fail(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	n.update(func(o *Observation) { o.LastErr = msg })
}

func (n *Node) run(ctx context.Context) {
	defer close(n.done)
	startedClosed := false
	closeStarted := func() {
		if !startedClosed {
			startedClosed = true
			close(n.started)
		}
	}
	defer closeStarted()
	if ctx.Err() != nil {
		return
	}

	if err := prepareStateDir(n.opts.StateDir); err != nil {
		n.fail("The Tailscale folder could not be prepared: %v", err)
		closeStarted()
		return
	}
	// The node's own logs stay on this Mac: logtail would otherwise upload them to Tailscale's log service.
	logtail.Disable()
	// Port mapping probes the local network for a router (SSDP and the
	// gateway), which makes macOS ask the person to allow local network
	// access. Funnel and the public listener do not use it.
	envknob.Setenv("TS_DISABLE_PORTMAPPER", "1")
	for first := true; ctx.Err() == nil; first = false {
		// A server that is restarted keeps the folder, and with it the key.
		gctx, gcancel := context.WithCancel(ctx)
		n.mu.Lock()
		n.restart = gcancel
		n.mu.Unlock()
		api, err := n.opts.startNode(n.opts.StateDir, n.opts.Hostname, n.logLine)
		closeStarted()
		if err == nil {
			n.mu.Lock()
			n.api = api
			if rn, ok := api.(*realNode); ok {
				n.srv = rn.s
			}
			close(n.nextUp)
			n.nextUp = make(chan struct{})
			n.mu.Unlock()
			n.watch(gctx, api)
		}
		gcancel()
		n.mu.Lock()
		n.restart = nil
		n.mu.Unlock()
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			if first {
				n.fail("Tailscale could not start: %v", err)
				return
			}
			if !n.sleep(ctx, retryMax) {
				return
			}
			continue
		}
		// Only a restart ends the watch while ctx lives. The old server is
		// closed before the new one takes the folder.
		_ = api.Close()
		n.update(func(o *Observation) {
			o.Backend, o.LoginURL, o.NodeIPv4, o.CertDomains, o.FunnelURL = "", "", "", nil, ""
			o.Listening, o.FunnelAllowed, o.PublicAnswered = false, false, false
		})
	}
}

// realNode is the Tailscale server the engine runs.
type realNode struct {
	s  *tsnet.Server
	lc *local.Client

	mu     sync.Mutex
	parked map[ipn.HostPort]bool // the Funnel entries taken out of the serve config
}

// realStart starts a Tailscale server on dir, against controlURL when it is
// set.
func realStart(controlURL string) func(dir, hostname string, logf func(string, ...any)) (nodeAPI, error) {
	return func(dir, hostname string, logf func(string, ...any)) (nodeAPI, error) {
		s := &tsnet.Server{Dir: dir, Hostname: hostname, ControlURL: controlURL, Logf: logf, UserLogf: logf}
		if err := s.Start(); err != nil {
			_ = s.Close()
			return nil, err
		}
		lc, err := s.LocalClient()
		if err != nil {
			_ = s.Close()
			return nil, err
		}
		return &realNode{s: s, lc: lc}, nil
	}
}

func (r *realNode) Status(ctx context.Context) (*ipnstate.Status, error) {
	return r.lc.StatusWithoutPeers(ctx)
}

func (r *realNode) QueryFunnel(ctx context.Context) (*tailcfg.QueryFeatureResponse, error) {
	return r.lc.QueryFeature(ctx, "funnel")
}

func (r *realNode) StartLogin(ctx context.Context) error { return r.lc.StartLoginInteractive(ctx) }

func (r *realNode) Logout(ctx context.Context) error { return r.lc.Logout(ctx) }

func (r *realNode) Close() error { return r.s.Close() }

// SetFunnelAllowed reads the serve config, takes the Funnel entries out of it
// or puts back the ones it took out, and writes it. The listener and every
// other entry are left alone.
func (r *realNode) SetFunnelAllowed(ctx context.Context, allowed bool) error {
	sc, err := r.lc.GetServeConfig(ctx)
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if allowed {
		if len(r.parked) == 0 {
			return errors.New("tailnode: no Funnel entry to put back")
		}
		for hp := range r.parked {
			if sc.AllowFunnel == nil {
				sc.AllowFunnel = map[ipn.HostPort]bool{}
			}
			sc.AllowFunnel[hp] = true
		}
	} else {
		parked := map[ipn.HostPort]bool{}
		for hp, on := range sc.AllowFunnel {
			if on {
				parked[hp] = true
				delete(sc.AllowFunnel, hp)
			}
		}
		if len(parked) == 0 {
			return errors.New("tailnode: Funnel is already off in the serve config")
		}
		r.parked = parked
	}
	if err := r.lc.SetServeConfig(ctx, sc); err != nil {
		return err
	}
	if allowed {
		r.parked = nil
	}
	return nil
}

func (r *realNode) Watch(ctx context.Context) (ipnWatcher, error) {
	return r.lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
}

// ListenFunnel cannot be cancelled by the server, so whatever it returns after
// ctx is done is closed here and never holds the port.
func (r *realNode) ListenFunnel(ctx context.Context) (net.Listener, error) {
	type result struct {
		ln  net.Listener
		err error
	}
	res := make(chan result, 1)
	go func() {
		ln, err := r.s.ListenFunnel("tcp", publicPort)
		res <- result{ln, err}
	}()
	select {
	case v := <-res:
		return v.ln, v.err
	case <-ctx.Done():
		go func() {
			if v := <-res; v.ln != nil {
				_ = v.ln.Close()
			}
		}()
		return nil, ctx.Err()
	}
}

// WarmCertificate makes the node fetch or issue the certificate for host.
// Issuing the first one takes tens of seconds, so it is asked for with its own
// time, which keeps that wait out of the handshake of the public test.
func (r *realNode) WarmCertificate(ctx context.Context, host string) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = r.lc.GetCertificate(&tls.ClientHelloInfo{ServerName: host})
	}()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

// sleep waits for d on the node's clock.
func (n *Node) sleep(ctx context.Context, d time.Duration) bool {
	if n.opts.sleep != nil {
		return n.opts.sleep(ctx, d)
	}
	return sleep(ctx, d)
}

// logLine receives the node's own log lines. Only the monitor reads them, and
// it keeps counts, never a line: nothing is formatted, since a line can name an
// address. The end of a control map session is logged as one format with its
// label as the first argument, so that argument, and nothing else of the
// arguments, is read.
func (n *Node) logLine(format string, args ...any) {
	n.mon.ObserveLog(format)
	if strings.Contains(format, "[v1] %s: %v") && len(args) > 0 {
		if label, ok := args[0].(string); ok && label == "PollNetMap" {
			n.mon.ObserveLog(lineMapEnded)
		}
	}
}

// prepareStateDir creates dir, or tightens it, to mode 0700 regardless of
// the process umask, and keeps it out of backups: it holds the node's key.
func prepareStateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	return excludeFromBackup(dir)
}

// watch follows the node's own state notifications until ctx is done,
// starting a serving cycle whenever the node is running and ending it when
// it stops.
func (n *Node) watch(ctx context.Context, api nodeAPI) {
	var cycleCancel context.CancelFunc
	defer func() {
		if cycleCancel != nil {
			cycleCancel()
		}
	}()
	// The last cycle is waited for on the way out, so it has stopped its
	// server before the node is closed.
	defer func() {
		if prev := n.takePrev(); prev != nil {
			<-prev
		}
	}()
	backoff := retryFirst
	for ctx.Err() == nil {
		w, err := api.Watch(ctx)
		if err != nil {
			if !n.sleep(ctx, backoff) {
				return
			}
			backoff = min(backoff*2, retryMax)
			continue
		}
		backoff = retryFirst
		for {
			note, err := w.Next()
			if err != nil {
				_ = w.Close()
				break
			}
			if note.BrowseToURL != nil {
				n.setLoginURL(*note.BrowseToURL)
			}
			if note.State == nil {
				continue
			}
			state := note.State.String()
			n.update(func(o *Observation) {
				o.Backend = state
				if state != "NeedsLogin" {
					o.LoginURL = ""
				}
			})
			if *note.State == ipn.NeedsLogin {
				n.askForLoginURL(ctx, api)
			}
			if *note.State == ipn.Running {
				if cycleCancel == nil {
					cctx, cancel := context.WithCancel(ctx)
					cycleCancel = cancel
					prev := n.takePrev()
					done := make(chan struct{})
					n.setPrev(done)
					go func() {
						defer close(done)
						n.serve(cctx, api, prev)
					}()
				}
				continue
			}
			if cycleCancel != nil {
				cycleCancel()
				cycleCancel = nil
			}
			n.update(func(o *Observation) { o.Listening, o.FunnelAllowed, o.PublicAnswered = false, false, false })
		}
	}
}

func (n *Node) takePrev() chan struct{} {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.prevDone
}

func (n *Node) setPrev(c chan struct{}) {
	n.mu.Lock()
	n.prevDone = c
	n.mu.Unlock()
}

// setLoginURL records the sign-in page the node asked for. Only an https
// address is kept, since the app opens what it is given.
func (n *Node) setLoginURL(raw string) {
	if raw == "" {
		return
	}
	if u, err := url.Parse(raw); err != nil || u.Scheme != "https" || u.Host == "" {
		return
	}
	n.update(func(o *Observation) { o.LoginURL = raw })
}

// askForLoginURL asks the node for a sign-in page when it still needs one
// after loginURLGrace, which a node that was signed out later has no other
// way to give.
func (n *Node) askForLoginURL(ctx context.Context, api nodeAPI) {
	time.AfterFunc(loginURLGrace, func() {
		if ctx.Err() != nil {
			return
		}
		n.mu.Lock()
		need := n.obs.Backend == "NeedsLogin" && n.obs.LoginURL == ""
		n.mu.Unlock()
		if need {
			_ = api.StartLogin(ctx)
		}
	})
}

// serve runs one cycle while the node is running: it turns the public
// listener on once Funnel is allowed, waits for the public address to answer,
// and starts over if Funnel stops being allowed. It ends when ctx is done.
func (n *Node) serve(ctx context.Context, api nodeAPI, prev <-chan struct{}) {
	if prev != nil {
		select {
		case <-prev:
		case <-ctx.Done():
			return
		}
	}
	for ctx.Err() == nil {
		n.session(ctx, api)
		n.update(func(o *Observation) { o.Listening, o.FunnelAllowed, o.PublicAnswered = false, false, false })
	}
}

// refresh reads the node's addresses, the names it may get a certificate for
// and when its key expires. When the read fails nothing is changed and the
// error is returned, so a caller never goes on as if the old values were
// current.
func (n *Node) refresh(ctx context.Context, api nodeAPI) (*ipnstate.Status, error) {
	st, err := api.Status(ctx)
	if err != nil {
		return nil, err
	}
	n.applyStatus(st)
	return st, nil
}

func (n *Node) applyStatus(st *ipnstate.Status) {
	ip := ""
	for _, a := range st.TailscaleIPs {
		if a.Is4() {
			ip = a.String()
			break
		}
	}
	domains := append([]string(nil), st.CertDomains...)
	var expiry time.Time
	if st.Self != nil && st.Self.KeyExpiry != nil {
		expiry = *st.Self.KeyExpiry
	}
	n.update(func(o *Observation) { o.NodeIPv4, o.CertDomains, o.KeyExpiry = ip, domains, expiry })
}

// StartSignIn starts the node's interactive sign-in. The page it names reaches
// the status as the page to sign in again at, while the node keeps running.
func (n *Node) StartSignIn(ctx context.Context) error {
	n.mu.Lock()
	api := n.api
	n.mu.Unlock()
	if api == nil {
		return ErrNotServing
	}
	return api.StartLogin(ctx)
}

// openListener is the public listener and the server on it, with the
// handles a repair needs to open them again.
type openListener struct {
	api    nodeAPI
	srv    *http.Server
	served chan struct{} // closed when srv has stopped serving
}

// open turns Funnel on and serves the relay on it. It returns false when ctx
// is done.
func (n *Node) open(ctx context.Context, api nodeAPI) (*openListener, bool) {
	ln, ok := n.listen(ctx, api)
	if !ok {
		return nil, false
	}
	srv := n.opts.NewServer(PublicHandler(n.opts.Handler))
	// A request that fails on the public listener comes from the internet;
	// its error text carries the sender's address, so none of it is kept.
	srv.ErrorLog = log.New(io.Discard, "", 0)
	srv.IdleTimeout = PublicIdleTimeout
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = srv.Serve(&senderCounter{Listener: PerSenderListener(LimitListener(ln, MaxPublicConns), MaxConnsPerSender), mon: n.mon})
	}()
	answered := n.mon.Answered()
	now := n.now()
	n.update(func(o *Observation) {
		o.Listening, o.FunnelAllowed, o.FunnelURL = true, true, ""
		// The wait for the first answer begins when the address first starts
		// being served, and not again when the listener is reopened.
		if !answered && o.PublishingSince.IsZero() {
			o.PublishingSince = now
		}
	})
	return &openListener{api: api, srv: srv, served: served}, true
}

// senderCounter counts each connection the public listener accepts by
// whether its sender is inside the tailnet address range.
type senderCounter struct {
	net.Listener
	mon *Monitor
}

func (l *senderCounter) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err == nil {
		l.mon.ObserveSender(SenderInTailnet(c))
	}
	return c, err
}

func (l *openListener) stop() {
	sctx, cancel := context.WithTimeout(context.Background(), serverShutdownTimeout)
	defer cancel()
	if l.srv.Shutdown(sctx) != nil {
		_ = l.srv.Close()
	}
	<-l.served
}

// reopen closes the public listener and opens it again. It runs inside the
// session that is serving, which is where the monitor's repairs are made.
func (n *Node) reopen(ctx context.Context) error {
	n.mu.Lock()
	old := n.cur
	n.mu.Unlock()
	if old == nil {
		return ErrNotServing
	}
	old.stop()
	n.update(func(o *Observation) { o.Listening = false })
	fresh, ok := n.open(ctx, old.api)
	if !ok {
		return ctx.Err()
	}
	n.mu.Lock()
	n.cur = fresh
	n.mu.Unlock()
	return nil
}

func (n *Node) currentServed() <-chan struct{} {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.cur == nil {
		return nil
	}
	return n.cur.served
}

// policyOK reports whether the node's tailnet still allows Funnel for it.
func policyOK(st *ipnstate.Status) bool {
	return len(st.CertDomains) > 0 && st.Self != nil && ipn.CheckFunnelAccess(443, st.Self) == nil
}

// nodeHealth is what the status says about the node itself.
func nodeHealth(st *ipnstate.Status, err error) ProbeClass {
	switch {
	case err != nil || st == nil:
		return ProbeStatusRead
	case st.Self == nil || !st.Self.Online:
		return ProbeNodeOffline
	case len(st.Health) > 0:
		return ProbeNodeHealth
	}
	return ProbeOK
}

// host is the public name, once the node has one.
func (n *Node) host() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	if len(n.obs.CertDomains) > 0 {
		return n.obs.CertDomains[0]
	}
	return ""
}

// session listens for Funnel traffic, serves the relay on it and tests it,
// until Funnel stops being allowed, the listener dies or ctx is done.
func (n *Node) session(ctx context.Context, api nodeAPI) {
	l, ok := n.open(ctx, api)
	if !ok {
		return
	}
	n.mu.Lock()
	n.cur = l
	n.mu.Unlock()
	defer func() {
		n.mu.Lock()
		cur := n.cur
		n.cur = nil
		n.mu.Unlock()
		cur.stop()
	}()
	n.serving.Store(true)
	defer n.serving.Store(false)

	var wait time.Duration
	if n.mon.Answered() {
		// The address has answered before, so the first test is not repeated;
		// the monitor's tests decide from here.
		n.update(func(o *Observation) { o.PublicAnswered = true })
		wait = max(n.mon.Due(), settleWait)
	} else {
		if !n.publish(ctx, api) {
			return
		}
		wait = n.mon.Due()
	}

	// Lines the node logged while it started are not a reconnect of a
	// registration it has only now made.
	n.mon.ForgetReconnects()
	t := time.NewTimer(wait)
	defer t.Stop()
	// read reads the status, which ends the session if the tailnet no longer
	// allows Funnel, and returns the public name. The monitor judges the node
	// by this read, so a failed one is a failed test and never leaves the old
	// state standing.
	read := func() (string, bool) {
		st, err := n.refresh(ctx, api)
		if err == nil && !policyOK(st) {
			return "", false
		}
		n.mu.Lock()
		n.read, n.readErr = st, err
		n.mu.Unlock()
		return n.host(), true
	}
	for {
		var try chan struct{}
		timer := false
		select {
		case <-ctx.Done():
			return
		case <-n.currentServed():
			return
		case <-t.C:
			timer = true
		case try = <-n.tryCh:
		case <-n.mon.Reconnects():
		}
		next := time.Duration(-1)
		// A reconnect seen before this wake is acted on first, whatever woke
		// the session, so a press made after the line finds it done.
		if n.mon.ReconnectPending() {
			host, ok := read()
			if !ok {
				if try != nil {
					close(try)
				}
				return
			}
			if host != "" {
				if d, ran := n.mon.AfterReconnect(ctx, host); ran {
					next = d
				}
			}
		}
		if timer || try != nil {
			host, ok := read()
			if ok && host != "" {
				if try != nil {
					next = n.mon.TryAgain(ctx, host)
				} else {
					next = n.mon.Step(ctx, host)
				}
			} else if ok {
				next = n.mon.Due()
			}
			if try != nil {
				close(try)
			}
			if !ok {
				return
			}
		}
		if ctx.Err() != nil {
			return
		}
		if next >= 0 {
			t.Reset(next)
		}
	}
}

// publish makes the public tests of a new address until one is answered, and
// reports whether one was. A new public name can take minutes to exist and a
// relay can drop a connection meanwhile, so no failure here ends the wait; the
// state turns to not reachable by its own age. A person who presses Try Again
// has Funnel registered again on the running node, within the press limits,
// and tested at once.
func (n *Node) publish(ctx context.Context, api nodeAPI) bool {
	wait := publishFirst
	var try chan struct{}
	first := true
	for {
		if !first && try == nil {
			var ok bool
			d := wait
			wait = min(wait*2, publishMax)
			if try, ok = n.waitOrTry(ctx, d); !ok {
				return false
			}
			if try != nil && n.pressReregister(ctx) {
				// Registering again starts the wait over.
				now := n.now()
				n.update(func(o *Observation) { o.PublishingSince = now })
			}
		}
		first = false
		answered := n.publicTest(ctx, api)
		if try != nil {
			close(try)
			try = nil
		}
		if ctx.Err() != nil {
			return false
		}
		if answered {
			return true
		}
	}
}

// publicTest makes one test of the address and, when it is answered, records
// it as the first. A failed test is only counted.
func (n *Node) publicTest(ctx context.Context, api nodeAPI) bool {
	if _, err := n.refresh(ctx, api); err != nil {
		return false
	}
	host := n.host()
	if host == "" {
		return false
	}
	api.WarmCertificate(ctx, host)
	if ctx.Err() != nil {
		return false
	}
	class := n.probe(ctx, host)
	if ctx.Err() != nil {
		return false
	}
	if class != ProbeOK {
		n.mon.NoteFailure(class)
		return false
	}
	n.mon.MarkAnswered()
	n.update(func(o *Observation) {
		o.PublicAnswered = true
		o.PublishingSince = time.Time{}
		o.TailscaleErr, o.TailscaleErrClass = "", ""
	})
	return true
}

// waitOrTry waits d, or until a Try Again arrives, which it returns. It
// reports false when ctx is done.
func (n *Node) waitOrTry(ctx context.Context, d time.Duration) (chan struct{}, bool) {
	wctx, cancel := context.WithCancel(ctx)
	defer cancel()
	slept := make(chan bool, 1)
	go func() { slept <- n.sleep(wctx, d) }()
	select {
	case ok := <-slept:
		return nil, ok
	case try := <-n.tryCh:
		cancel()
		<-slept
		return try, ctx.Err() == nil
	case <-ctx.Done():
		cancel()
		<-slept
		return nil, false
	}
}

// reconnectWait is the longest a node that has just found Funnel allowed waits
// for the control server to reset its session before it registers anyway. It
// is under a minute so that the wait and the first wait after registering,
// publishFirst, together stay within one.
const reconnectWait = time.Minute - publishFirst

// waitForReset waits until a reconnect line is seen or reconnectWait has passed
// on the node's clock, and reports false when ctx is done. Lines seen before
// the wait began are not the reset it waits for.
func (n *Node) waitForReset(ctx context.Context) bool {
	n.mon.ForgetReconnects()
	wctx, cancel := context.WithCancel(ctx)
	defer cancel()
	slept := make(chan bool, 1)
	go func() { slept <- n.sleep(wctx, reconnectWait) }()
	select {
	case <-slept:
	case <-n.mon.Reconnects():
		cancel()
		<-slept
	}
	return ctx.Err() == nil
}

// listen turns Funnel on, retrying on a short backoff while it is refused,
// and keeping the text of each refusal for the person. It returns false when
// ctx is done. A node that ran while Funnel was not allowed listens again on
// the same running node once it is, and is never restarted for it: a restart
// just before registering lets the server's cleanup of the old session remove
// the new one's registration. A policy change also has the control server reset
// the node's session, and a registration made just before that reset is lost, so
// the node waits for the next reconnect line, at most reconnectWait, before it
// listens. A node whose tailnet allowed Funnel from the start listens at once.
//
// The listener is not Funnel-only: a phone that also runs Tailscale resolves
// the public name to the node's tailnet address, and a Funnel-only listener
// refuses it.
func (n *Node) listen(ctx context.Context, api nodeAPI) (net.Listener, bool) {
	wait := retryFirst
	wasOff := false
	for {
		st, err := n.refresh(ctx, api)
		if err != nil {
			// Without a current read the node cannot be told to listen.
			if !n.sleep(ctx, wait) {
				return nil, false
			}
			wait = min(wait*2, retryMax)
			continue
		}
		if !policyOK(st) {
			wasOff = true
		} else if wasOff {
			wasOff = false
			// While it waits the address is publishing, with none of the
			// refusals from before Funnel was allowed; they are shown again if
			// the node is refused once the wait is over.
			var text, class string
			n.update(func(o *Observation) {
				text, class = o.TailscaleErr, o.TailscaleErrClass
				o.TailscaleErr, o.TailscaleErrClass = "", ""
				o.Listening, o.FunnelAllowed, o.FunnelURL = false, true, ""
			})
			ok := n.waitForReset(ctx)
			n.update(func(o *Observation) {
				if o.TailscaleErr == "" {
					o.TailscaleErr, o.TailscaleErrClass = text, class
				}
			})
			if !ok {
				return nil, false
			}
		}
		fr, qerr := api.QueryFunnel(ctx)
		funnelURL := ""
		if qerr == nil && !fr.Complete {
			funnelURL = fr.URL
		}
		n.update(func(o *Observation) { o.FunnelURL = funnelURL })

		ln, lerr := api.ListenFunnel(ctx)
		if lerr == nil {
			return ln, true
		}
		if ctx.Err() != nil {
			return nil, false
		}
		// The text may name an address or the host, so it goes to the status
		// for the person and nowhere else; only its class is counted.
		text := lerr.Error()
		n.update(func(o *Observation) {
			o.Listening, o.FunnelAllowed = false, false
			o.TailscaleErr, o.TailscaleErrClass = text, ClassifyTailscaleError(text)
		})
		if !n.sleep(ctx, wait) {
			return nil, false
		}
		wait = min(wait*2, retryMax)
	}
}

// sleep waits for d or ctx, and reports whether the full wait passed.
func sleep(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}
