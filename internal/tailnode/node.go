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
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/logtail"
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
}

// Node is a running built-in Tailscale node.
type Node struct {
	opts   Options
	now    func() time.Time
	cancel context.CancelFunc

	started chan struct{} // closed once Start has returned
	done    chan struct{} // closed when the run goroutine has ended

	mon     *Monitor
	serving atomic.Bool
	tryCh   chan chan struct{} // a pending Try Again, answered when its test is done

	mu       sync.Mutex
	srv      *tsnet.Server
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
	n.mon = NewMonitor(MonitorOptions{Now: n.now, Probe: NewPublicProbe(), Node: n.nodeCheck, Repair: nodeRepair{n}})
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
// fails, then returns. It returns ErrNotServing while there is no listener to
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
// are kept because the folder is.
func (n *Node) Restart(ctx context.Context) error {
	n.mu.Lock()
	up := n.nextUp
	n.mu.Unlock()
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

// nodeRepair is the Monitor's way of repairing the node.
type nodeRepair struct{ n *Node }

func (r nodeRepair) ReopenListener(ctx context.Context) error { return r.n.reopen(ctx) }

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
	srv := n.srv
	n.mu.Unlock()
	if srv != nil {
		closed := make(chan struct{})
		go func() { _ = srv.Close(); close(closed) }()
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
		s := &tsnet.Server{
			Dir:        n.opts.StateDir,
			Hostname:   n.opts.Hostname,
			ControlURL: n.opts.controlURL,
			Logf:       n.logLine,
			UserLogf:   n.logLine,
		}
		gctx, gcancel := context.WithCancel(ctx)
		n.mu.Lock()
		n.srv = s
		n.restart = gcancel
		n.mu.Unlock()
		err := s.Start()
		closeStarted()
		if err == nil {
			var lc *local.Client
			if lc, err = s.LocalClient(); err == nil {
				n.mu.Lock()
				close(n.nextUp)
				n.nextUp = make(chan struct{})
				n.mu.Unlock()
				n.watch(gctx, lc, s)
			}
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
			_ = s.Close()
			if !sleep(ctx, retryMax) {
				return
			}
			continue
		}
		// Only a restart ends the watch while ctx lives. The old server is
		// closed before the new one takes the folder.
		_ = s.Close()
		n.update(func(o *Observation) {
			o.Backend, o.LoginURL, o.NodeIPv4, o.CertDomains, o.FunnelURL = "", "", "", nil, ""
			o.Listening, o.FunnelAllowed, o.PublicAnswered = false, false, false
		})
	}
}

// logLine receives the node's own log lines. Only the monitor's two counts
// read them; nothing is formatted or kept, since a line can name an address.
func (n *Node) logLine(format string, _ ...any) { n.mon.ObserveLog(format) }

// prepareStateDir creates dir, or tightens it, to mode 0700 regardless of
// the process umask: it holds the node's key.
func prepareStateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}

// watch follows the node's own state notifications until ctx is done,
// starting a serving cycle whenever the node is running and ending it when
// it stops.
func (n *Node) watch(ctx context.Context, lc *local.Client, s *tsnet.Server) {
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
		w, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
		if err != nil {
			if !sleep(ctx, backoff) {
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
				n.askForLoginURL(ctx, lc)
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
						n.serve(cctx, lc, s, prev)
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
func (n *Node) askForLoginURL(ctx context.Context, lc *local.Client) {
	time.AfterFunc(loginURLGrace, func() {
		if ctx.Err() != nil {
			return
		}
		n.mu.Lock()
		need := n.obs.Backend == "NeedsLogin" && n.obs.LoginURL == ""
		n.mu.Unlock()
		if need {
			_ = lc.StartLoginInteractive(ctx)
		}
	})
}

// serve runs one cycle while the node is running: it turns the public
// listener on once Funnel is allowed, confirms the public address answers,
// and starts over if Funnel stops being allowed. It ends when ctx is done.
func (n *Node) serve(ctx context.Context, lc *local.Client, s *tsnet.Server, prev <-chan struct{}) {
	if prev != nil {
		select {
		case <-prev:
		case <-ctx.Done():
			return
		}
	}
	for ctx.Err() == nil {
		n.session(ctx, lc, s)
		n.update(func(o *Observation) { o.Listening, o.FunnelAllowed, o.PublicAnswered = false, false, false })
	}
}

// refresh reads the node's addresses and the names it may get a certificate
// for. When the read fails nothing is changed and the error is returned, so a
// caller never goes on as if the old values were current.
func (n *Node) refresh(ctx context.Context, lc *local.Client) error {
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return err
	}
	n.applyStatus(st)
	return nil
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
	n.update(func(o *Observation) { o.NodeIPv4, o.CertDomains = ip, domains })
}

// openListener is the public listener and the server on it, with the
// handles a repair needs to open them again.
type openListener struct {
	lc     *local.Client
	s      *tsnet.Server
	srv    *http.Server
	served chan struct{} // closed when srv has stopped serving
}

// open turns Funnel on and serves the relay on it. It returns false when ctx
// is done.
func (n *Node) open(ctx context.Context, lc *local.Client, s *tsnet.Server) (*openListener, bool) {
	ln, ok := n.listen(ctx, lc, s)
	if !ok {
		return nil, false
	}
	srv := n.opts.NewServer(PublicHandler(n.opts.Handler))
	// A request that fails on the public listener comes from the internet;
	// its error text carries the sender's address, so none of it is kept.
	srv.ErrorLog = log.New(io.Discard, "", 0)
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = srv.Serve(LimitListener(ln, MaxPublicConns))
	}()
	n.update(func(o *Observation) { o.Listening, o.FunnelAllowed, o.FunnelURL = true, true, "" })
	return &openListener{lc: lc, s: s, srv: srv, served: served}, true
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
	fresh, ok := n.open(ctx, old.lc, old.s)
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
	return len(st.CertDomains) > 0 && ipn.CheckFunnelAccess(443, st.Self) == nil
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

// session listens for Funnel traffic, serves the relay on it and tests it,
// until Funnel stops being allowed, the listener dies or ctx is done.
func (n *Node) session(ctx context.Context, lc *local.Client, s *tsnet.Server) {
	l, ok := n.open(ctx, lc, s)
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

	wait := settleWait
	if n.mon.Answered() {
		// The address has answered before, so the node's own first request
		// is not repeated; the monitor's tests decide from here.
		n.update(func(o *Observation) { o.PublicAnswered = true })
		wait = max(n.mon.Due(), settleWait)
	} else {
		if !n.waitPublic(ctx, lc) {
			return
		}
		n.mon.MarkAnswered()
		wait = n.mon.Due()
	}

	n.serving.Store(true)
	defer n.serving.Store(false)
	t := time.NewTimer(wait)
	defer t.Stop()
	// test reads the status, ends the session if the tailnet no longer
	// allows Funnel, and otherwise makes one test. It returns the wait before
	// the next one and whether the session goes on.
	test := func(try bool) (time.Duration, bool) {
		st, err := lc.StatusWithoutPeers(ctx)
		if err == nil {
			if !policyOK(st) {
				return 0, false
			}
			n.applyStatus(st)
		}
		// The monitor judges the node by this read, so a failed one is a
		// failed test and never leaves the old state standing.
		n.mu.Lock()
		n.read, n.readErr = st, err
		var host string
		if len(n.obs.CertDomains) > 0 {
			host = n.obs.CertDomains[0]
		}
		n.mu.Unlock()
		if host == "" {
			return n.mon.Due(), true
		}
		if try {
			return n.mon.TryAgain(ctx, host), true
		}
		return n.mon.Step(ctx, host), true
	}
	for {
		var try chan struct{}
		select {
		case <-ctx.Done():
			return
		case <-n.currentServed():
			return
		case <-t.C:
		case try = <-n.tryCh:
		}
		d, ok := test(try != nil)
		if try != nil {
			close(try)
		}
		if !ok || ctx.Err() != nil {
			return
		}
		t.Reset(d)
	}
}

// listen turns Funnel on, retrying on a short backoff while it is refused
// and offering the page that fixes it. It returns false when ctx is done.
//
// The listener is not Funnel-only: a phone that also runs Tailscale resolves
// the public name to the node's tailnet address, and a Funnel-only listener
// refuses it.
func (n *Node) listen(ctx context.Context, lc *local.Client, s *tsnet.Server) (net.Listener, bool) {
	wait := retryFirst
	for {
		if n.refresh(ctx, lc) != nil {
			// Without a current read the node cannot be told to listen.
			if !sleep(ctx, wait) {
				return nil, false
			}
			wait = min(wait*2, retryMax)
			continue
		}
		fr, err := lc.QueryFeature(ctx, "funnel")
		funnelURL := ""
		if err == nil && !fr.Complete {
			funnelURL = fr.URL
		}
		n.update(func(o *Observation) { o.FunnelURL = funnelURL })

		type result struct {
			ln  net.Listener
			err error
		}
		res := make(chan result, 1)
		go func() {
			ln, err := s.ListenFunnel("tcp", publicPort)
			res <- result{ln, err}
		}()
		select {
		case r := <-res:
			if r.err == nil {
				return r.ln, true
			}
		case <-ctx.Done():
			// ListenFunnel cannot be cancelled; whatever it returns is
			// closed here so it never holds the port.
			go func() {
				if r := <-res; r.ln != nil {
					_ = r.ln.Close()
				}
			}()
			return nil, false
		}
		n.update(func(o *Observation) { o.Listening, o.FunnelAllowed = false, false })
		if !sleep(ctx, wait) {
			return nil, false
		}
		wait = min(wait*2, retryMax)
	}
}

// waitPublic makes the node's first request to its own public address and
// repeats it on a backoff until one is answered or ctx is done. The request
// goes through the machine's own network and resolver, not the node's
// dialer, so it travels the route a phone's request travels and a name that
// only the tailnet resolves cannot pass for the public one.
func (n *Node) waitPublic(ctx context.Context, lc *local.Client) bool {
	wait := retryFirst
	client := &http.Client{
		Timeout: publicAttemptTimeout,
		Transport: &http.Transport{
			DisableKeepAlives:   true,
			TLSHandshakeTimeout: publicAttemptTimeout,
		},
	}
	defer client.CloseIdleConnections()
	for {
		var host string
		if n.refresh(ctx, lc) == nil {
			n.mu.Lock()
			if len(n.obs.CertDomains) > 0 {
				host = n.obs.CertDomains[0]
			}
			n.mu.Unlock()
		}
		if host != "" {
			// Issuing the first certificate takes tens of seconds; asking for
			// it here, with its own time, keeps that wait out of the
			// handshake of the request below.
			n.warmCertificate(ctx, lc, host)
			if ctx.Err() != nil {
				return false
			}
			if answered(ctx, client, host) {
				n.update(func(o *Observation) { o.PublicAnswered = true })
				return true
			}
		}
		if !sleep(ctx, wait) {
			return false
		}
		wait = min(wait*2, retryMax)
	}
}

// warmCertificate makes the node fetch or issue the certificate for host.
func (n *Node) warmCertificate(ctx context.Context, lc *local.Client, host string) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = lc.GetCertificate(&tls.ClientHelloInfo{ServerName: host})
	}()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

func answered(ctx context.Context, client *http.Client, host string) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+host+publicCheckPath, nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	return resp.StatusCode == http.StatusOK
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
