// Package tailnode runs the engine's own Tailscale node, which gives the
// relay a public https address on the internet that only a valid token
// opens. This file holds the parts that need no network: the mapping from
// what the node reports to the state shown to the app, the limits on the
// waiting states, the path allowlist for the public listener and its
// connection cap. node.go holds the node itself.
package tailnode

import (
	"crypto/tls"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/nightscout"
	"tailscale.com/ipn"
)

// The states Status.State takes.
const (
	StateNeedsLogin    = "needs-login"
	StateNeedsApproval = "needs-approval"
	StateStarting      = "starting"
	StateNeedsFunnel   = "needs-funnel"
	StateSettingUp     = "setting-up"
	// StatePublishing is a listening node whose public address has not
	// answered yet, which a new public name can take minutes to do.
	StatePublishing = "publishing"
	// StateNotReachable is the same wait once PublishingWindow has passed.
	StateNotReachable = "not-reachable"
	StateRunning      = "running"
	// StateNotAnswering is a running node whose public address stopped
	// answering while the Mac's own network is fine; the engine is repairing it.
	StateNotAnswering = "not-answering"
	// StateWaitingForInternet is a running node whose test could not be made,
	// or could not say anything about the public route, because the Mac or the
	// node is offline or unhealthy. Nothing is repaired for it.
	StateWaitingForInternet = "waiting-for-internet"
	StateError              = "error"
)

// StartingLimit is how long the node may stay in starting before the state
// becomes an error. A node that is already signed in reaches running within
// seconds, and a first sign-in took under a minute from the sign-up to
// running, so two minutes leaves room for a slow network without leaving a
// stuck start unreported.
const StartingLimit = 2 * time.Minute

// PublishingWindow is how long a new address may go without an answer before
// the state says it is not reachable. Tailscale documents up to ten minutes
// for a new public name to appear, and a new tailnet has been seen to take
// longer, so the state stays publishing past it for another five.
const PublishingWindow = 15 * time.Minute

// Classes of the last error Tailscale gave, which are all that diagnostics
// carry of it.
const (
	ErrClassHTTPS         = "https_disabled"
	ErrClassNodeAttribute = "node_attribute_missing"
	ErrClassListen        = "listen_failed"
)

// ClassifyTailscaleError names the class of an error text from Tailscale,
// or "" for no error. The class never holds any of the text.
func ClassifyTailscaleError(text string) string {
	switch {
	case text == "":
		return ""
	case strings.Contains(text, "HTTPS must be enabled"):
		return ErrClassHTTPS
	case strings.Contains(text, `"funnel" node attribute`):
		return ErrClassNodeAttribute
	}
	return ErrClassListen
}

// ReadyFreshness is how old the last successful public test may be before
// the state stops saying running. Tests come every two minutes, so a healthy
// address never reaches it.
const ReadyFreshness = 6 * time.Minute

// MaxPublicConns caps the connections open at once on the public listener. A
// follower phone holds one or two, so the cap only ever bites a flood.
const MaxPublicConns = 128

// MaxConnsPerSender caps the public connections one sender holds open at once.
const MaxConnsPerSender = 8

// PublicIdleTimeout is how long an idle keep-alive connection stays open on
// the public listener.
const PublicIdleTimeout = 10 * time.Second

// approveURLBase is the admin console's machine pages; the page of one
// machine is this plus its tailnet address.
const approveURLBase = "https://login.tailscale.com/admin/machines"

// Observation is everything State needs to decide what to report.
type Observation struct {
	// Backend is the node's own state name: NeedsLogin, NeedsMachineAuth,
	// Starting, Running and so on. An empty or unknown name counts as Starting.
	Backend string
	// LoginURL is the sign-in page the node asked to be opened.
	LoginURL string
	// NodeIPv4 is the node's tailnet IPv4 address, once it has one.
	NodeIPv4 string
	// CertDomains are the names the node may get a certificate for. The
	// public host is the first of them and never the hostname.
	CertDomains []string
	// FunnelAllowed reports that the node's tailnet allows Funnel for it.
	FunnelAllowed bool
	// FunnelURL is the page that turns on Funnel, while it is off.
	FunnelURL string
	// Listening reports that the public listener is serving.
	Listening bool
	// PublicAnswered reports that a request the node made to its own public
	// address was answered.
	PublicAnswered bool
	// PublishingSince is when the public address first began to be served,
	// while it has not answered; the wait for the first answer is timed from it.
	PublishingSince time.Time
	// TailscaleErr is the last error text Tailscale gave, kept for the person
	// and nowhere else, and TailscaleErrClass its class.
	TailscaleErr      string
	TailscaleErrClass string
	// KeyExpiry is when the node's key expires, zero when unknown.
	KeyExpiry time.Time
	// Now is the time of the observation. While it is set, running needs a
	// successful public test no older than ReadyFreshness before it.
	Now time.Time
	// CheckedAt is when the public address last answered a test.
	CheckedAt time.Time
	// NotAnsweringSince is when the run of failed tests that made the public
	// address stop answering began; zero while it answers.
	NotAnsweringSince time.Time
	// WaitingForInternet reports that the last test failed on the Mac's side
	// or the node's, which says nothing about the public route.
	WaitingForInternet bool
	// Counts are bounded counts of failure classes and of two kinds of
	// Tailscale log line, for diagnostics. They never hold a line or an address.
	Counts map[string]int
	// InStateFor is how long the observation has led to the same state.
	InStateFor time.Duration
	// LastErr is a failure the node cannot recover from by waiting.
	LastErr string
}

// Status is what the engine reports about the node, as the ts_* fields of
// its status endpoint. Only the fields that belong to the state are set.
type Status struct {
	State      string `json:"ts_state"`
	LoginURL   string `json:"ts_login_url,omitempty"`
	ApproveURL string `json:"ts_approve_url,omitempty"`
	FunnelURL  string `json:"ts_funnel_url,omitempty"`
	PublicHost string `json:"ts_public_host,omitempty"`
	Error      string `json:"ts_error,omitempty"`
	// CheckedAt is when the public address last answered, UTC, on a running
	// state.
	CheckedAt string `json:"ts_checked_at,omitempty"`
	// NotAnsweringSince is when the address stopped answering, UTC.
	NotAnsweringSince string         `json:"ts_not_answering_since,omitempty"`
	Counts            map[string]int `json:"ts_counts,omitempty"`
	// PublishingSince is when the address began to be served, UTC, while it
	// has not yet answered.
	PublishingSince string `json:"ts_publishing_since,omitempty"`
	// TailscaleError is the last text Tailscale gave, and ErrorClass its class.
	TailscaleError string `json:"ts_tailscale_error,omitempty"`
	ErrorClass     string `json:"ts_error_class,omitempty"`
	// KeyExpiry is when the node's key expires, UTC.
	KeyExpiry string `json:"ts_key_expiry,omitempty"`
	// SignInAgainURL is the page of a sign-in the node was asked to start while
	// it runs.
	SignInAgainURL string `json:"ts_sign_in_url,omitempty"`
}

// State maps an observation to the status to report. It reads no clock and
// does no I/O.
func State(o Observation) Status {
	s := stateOf(o)
	if len(o.Counts) > 0 {
		s.Counts = o.Counts
	}
	if !o.KeyExpiry.IsZero() {
		s.KeyExpiry = stamp(o.KeyExpiry)
	}
	if o.TailscaleErr != "" {
		s.TailscaleError, s.ErrorClass = o.TailscaleErr, o.TailscaleErrClass
	}
	if o.Backend == "Running" && o.LoginURL != "" {
		s.SignInAgainURL = o.LoginURL
	}
	return s
}

func stateOf(o Observation) Status {
	if o.LastErr != "" {
		return Status{State: StateError, Error: o.LastErr}
	}
	switch o.Backend {
	case "NeedsLogin":
		return Status{State: StateNeedsLogin, LoginURL: o.LoginURL}
	case "NeedsMachineAuth":
		url := approveURLBase
		if o.NodeIPv4 != "" {
			url += "/" + o.NodeIPv4
		}
		return Status{State: StateNeedsApproval, ApproveURL: url}
	case "Running":
		return running(o)
	default:
		if o.InStateFor >= StartingLimit {
			return Status{State: StateError, Error: "Tailscale did not finish starting in time. Check your internet connection and try again."}
		}
		return Status{State: StateStarting}
	}
}

func running(o Observation) Status {
	if len(o.CertDomains) == 0 || !o.FunnelAllowed {
		return Status{State: StateNeedsFunnel, FunnelURL: o.FunnelURL}
	}
	host := o.CertDomains[0]
	if !o.PublicAnswered {
		// Until the first answer the wait is not a failure, whatever the
		// tests report: a new name can take minutes to exist. Only a Mac
		// that cannot test says anything about the route, and only once the
		// window is over.
		s := Status{State: StatePublishing, PublicHost: host}
		if !o.PublishingSince.IsZero() {
			s.PublishingSince = stamp(o.PublishingSince)
			if !o.Now.IsZero() && o.Now.Sub(o.PublishingSince) >= PublishingWindow {
				if o.WaitingForInternet {
					return Status{State: StateWaitingForInternet, PublicHost: host}
				}
				return Status{State: StateNotReachable, PublicHost: host}
			}
		}
		return s
	}
	// A Mac that cannot test says nothing about the route, so it outranks a
	// not-answering report from before.
	if o.WaitingForInternet {
		return Status{State: StateWaitingForInternet, PublicHost: host}
	}
	if !o.NotAnsweringSince.IsZero() {
		return Status{State: StateNotAnswering, PublicHost: host, NotAnsweringSince: stamp(o.NotAnsweringSince)}
	}
	stale := !o.Now.IsZero() && (o.CheckedAt.IsZero() || o.Now.Sub(o.CheckedAt) > ReadyFreshness)
	if !o.Listening || stale {
		return Status{State: StateSettingUp, PublicHost: host}
	}
	s := Status{State: StateRunning, PublicHost: host}
	if !o.CheckedAt.IsZero() {
		s.CheckedAt = stamp(o.CheckedAt)
	}
	return s
}

func stamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// allowedExact are the paths of the follower API the relay serves. They are
// the paths internal/nightscout registers; a path added there is not public
// until it is added here. The v2 properties route is admitted by publicPath,
// since its names are a segment after the prefix.
var allowedExact = map[string]bool{
	"/":                            true,
	"/api/v1/status.json":          true,
	"/api/v1/entries/sgv.json":     true,
	"/api/v1/entries.json":         true,
	"/api/v1/entries/current.json": true,
	"/api/v1/experiments/test":     true,
	"/api/v1/treatments.json":      true,
	"/api/v1/treatments":           true,
	"/api/v1/devicestatus.json":    true,
	"/api/v1/devicestatus":         true,
	"/api/v1/profile":              true,
	"/api/v1/profiles.json":        true,
}

// connectPrefix is the pairing page, which carries a one-time code after it.
const connectPrefix = "/connect/"

// propertiesPath is the v2 properties route: bare, or with one segment of
// comma-separated names after it.
const propertiesPath = "/api/v2/properties"

// PublicHandler wraps next for the public listener: only the paths a
// follower app or a pairing page uses reach next, and every other path
// answers 404 without reaching it. An answer to a request that did not prove
// itself closes its connection: the 404, the 401, the open paths and the
// pairing page. A request that passed authentication keeps its connection.
func PublicHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !publicPath(r.URL.Path) {
			w.Header().Set("Connection", "close")
			http.NotFound(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, connectPrefix) || !nightscout.RequiresCredential(r) {
			w.Header().Set("Connection", "close")
		} else {
			w = &closeOn401{ResponseWriter: w}
		}
		next.ServeHTTP(w, r)
	})
}

// closeOn401 asks for the connection to close when the answer is a 401. It
// sets the header before the first byte of the answer goes out.
type closeOn401 struct {
	http.ResponseWriter
	wrote bool
}

func (w *closeOn401) WriteHeader(code int) {
	if !w.wrote {
		w.wrote = true
		if code == http.StatusUnauthorized {
			w.Header().Set("Connection", "close")
		}
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *closeOn401) Write(b []byte) (int, error) {
	w.wrote = true
	return w.ResponseWriter.Write(b)
}

func (w *closeOn401) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func publicPath(p string) bool {
	if allowedExact[p] {
		return true
	}
	if p == propertiesPath {
		return true
	}
	if rest, ok := strings.CutPrefix(p, propertiesPath+"/"); ok {
		return rest != "" && !strings.Contains(rest, "/")
	}
	rest, ok := strings.CutPrefix(p, connectPrefix)
	return ok && rest != "" && !strings.Contains(rest, "/")
}

// LimitListener returns a listener that holds at most n accepted
// connections open at once: Accept waits while n are open, and a closed
// connection frees its place.
func LimitListener(l net.Listener, n int) net.Listener {
	return &limitListener{Listener: l, sem: make(chan struct{}, n), done: make(chan struct{})}
}

type limitListener struct {
	net.Listener
	sem       chan struct{}
	done      chan struct{}
	closeOnce sync.Once
}

func (l *limitListener) Accept() (net.Conn, error) {
	select {
	case l.sem <- struct{}{}:
	case <-l.done:
		return nil, net.ErrClosed
	}
	c, err := l.Listener.Accept()
	if err != nil {
		<-l.sem
		return nil, err
	}
	return &limitConn{Conn: c, release: func() { <-l.sem }}, nil
}

func (l *limitListener) Close() error {
	err := l.Listener.Close()
	l.closeOnce.Do(func() { close(l.done) })
	return err
}

type limitConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *limitConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.release)
	return err
}

// NetConn is the connection this one wraps.
func (c *limitConn) NetConn() net.Conn { return c.Conn }

// SenderKey names the sender of c: the address of the client behind it, with
// no port, and for IPv6 its /64. A wrapper that exposes NetConn, a *tls.Conn
// and a Funnel connection are looked through, since a Funnel connection's own
// RemoteAddr is the relay's; a connection with no Funnel client behind it
// uses its RemoteAddr.
func SenderKey(c net.Conn) string {
	a, ok := senderAddr(c)
	if !ok {
		return c.RemoteAddr().String()
	}
	if a.Is6() && !a.Is4In6() {
		return netip.PrefixFrom(a, 64).Masked().String()
	}
	return a.String()
}

// senderAddr is the client's IP address behind c, when there is one.
func senderAddr(c net.Conn) (netip.Addr, bool) {
	for range 16 {
		switch v := c.(type) {
		case *ipn.FunnelConn:
			return v.Src.Addr().Unmap(), v.Src.IsValid()
		case *tls.Conn:
			c = v.NetConn()
			continue
		case interface{ NetConn() net.Conn }:
			c = v.NetConn()
			continue
		}
		break
	}
	if c == nil {
		return netip.Addr{}, false
	}
	if ap, err := netip.ParseAddrPort(c.RemoteAddr().String()); err == nil {
		return ap.Addr().Unmap(), true
	}
	return netip.Addr{}, false
}

// SenderInTailnet reports whether the sender of c is inside the tailnet
// address range, which a Funnel client never is, whatever relay it came by.
func SenderInTailnet(c net.Conn) bool {
	a, ok := senderAddr(c)
	return ok && IsTailnetAddress(a)
}

// PerSenderListener returns a listener that holds at most perSender accepted
// connections open for one sender (see SenderKey). A connection over the cap
// is closed unserved inside Accept, which goes on to the next one and never
// returns an error for it. A closed connection frees its place, once.
func PerSenderListener(l net.Listener, perSender int) net.Listener {
	return &senderListener{Listener: l, max: perSender, held: map[string]int{}}
}

type senderListener struct {
	net.Listener
	max  int
	mu   sync.Mutex
	held map[string]int
}

func (l *senderListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		key := SenderKey(c)
		l.mu.Lock()
		over := l.held[key] >= l.max
		if !over {
			l.held[key]++
		}
		l.mu.Unlock()
		if over {
			_ = c.Close()
			continue
		}
		return &senderConn{Conn: c, release: func() {
			l.mu.Lock()
			if l.held[key]--; l.held[key] <= 0 {
				delete(l.held, key)
			}
			l.mu.Unlock()
		}}, nil
	}
}

type senderConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *senderConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.release)
	return err
}

// NetConn is the connection this one wraps.
func (c *senderConn) NetConn() net.Conn { return c.Conn }
