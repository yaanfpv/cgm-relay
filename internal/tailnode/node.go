package tailnode

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
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
	// recheckInterval is how often a running node checks that its tailnet
	// still allows Funnel for it, so a policy change moves the state back.
	recheckInterval = 2 * time.Minute
	// publicAttemptTimeout bounds one request to the node's own address.
	publicAttemptTimeout = 20 * time.Second
	// loginURLGrace is how long a node that needs a sign-in may lack a
	// sign-in page before one is asked for.
	loginURLGrace = 5 * time.Second
)

// publicCheckPath is answered without a token by the relay, and says only
// that it is up.
const publicCheckPath = "/api/v1/status.json"

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

	mu       sync.Mutex
	srv      *tsnet.Server
	obs      Observation
	key      string
	since    time.Time
	prevDone chan struct{} // the previous serving cycle's end
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
	}
	if n.now == nil {
		n.now = time.Now
	}
	n.since = n.now()
	ctx, cancel := context.WithCancel(context.Background())
	n.cancel = cancel
	go n.run(ctx)
	return n
}

// Status is the node's current status.
func (n *Node) Status() Status {
	n.mu.Lock()
	defer n.mu.Unlock()
	o := n.obs
	o.InStateFor = n.now().Sub(n.since)
	return State(o)
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
	key := State(n.obs).State
	changed := key != n.key
	if changed {
		n.key = key
		n.since = n.now()
	}
	n.mu.Unlock()
	if changed && n.opts.Logf != nil {
		n.opts.Logf("built-in Tailscale: %s", key)
	}
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
	quiet := func(string, ...any) {}
	s := &tsnet.Server{
		Dir:        n.opts.StateDir,
		Hostname:   n.opts.Hostname,
		ControlURL: n.opts.controlURL,
		Logf:       quiet,
		UserLogf:   quiet,
	}
	n.mu.Lock()
	n.srv = s
	n.mu.Unlock()
	err := s.Start()
	closeStarted()
	if err != nil {
		n.fail("Tailscale could not start: %v", err)
		return
	}
	lc, err := s.LocalClient()
	if err != nil {
		n.fail("Tailscale could not start: %v", err)
		return
	}
	n.watch(ctx, lc, s)
}

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
// for.
func (n *Node) refresh(ctx context.Context, lc *local.Client) {
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return
	}
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

// session listens for Funnel traffic, serves the relay on it and checks it,
// until Funnel stops being allowed or ctx is done.
func (n *Node) session(ctx context.Context, lc *local.Client, s *tsnet.Server) {
	ln, ok := n.listen(ctx, lc, s)
	if !ok {
		return
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
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), serverShutdownTimeout)
		defer cancel()
		if srv.Shutdown(sctx) != nil {
			_ = srv.Close()
		}
		<-served
	}()
	n.update(func(o *Observation) { o.Listening, o.FunnelAllowed, o.FunnelURL = true, true, "" })

	if !n.waitPublic(ctx, lc) {
		return
	}
	// The public address answers; from here only a policy change or a dead
	// listener ends the session.
	t := time.NewTicker(recheckInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-served:
			return
		case <-t.C:
			st, err := lc.StatusWithoutPeers(ctx)
			if err != nil {
				continue
			}
			if len(st.CertDomains) == 0 || ipn.CheckFunnelAccess(443, st.Self) != nil {
				return
			}
		}
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
		n.refresh(ctx, lc)
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
		n.refresh(ctx, lc)
		n.mu.Lock()
		var host string
		if len(n.obs.CertDomains) > 0 {
			host = n.obs.CertDomains[0]
		}
		n.mu.Unlock()
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
