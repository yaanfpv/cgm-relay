// Package tailnode runs the engine's own Tailscale node, which gives the
// relay a public https address on the internet that only a valid token
// opens. This file holds the parts that need no network: the mapping from
// what the node reports to the state shown to the app, the limits on the
// waiting states, the path allowlist for the public listener and its
// connection cap. node.go holds the node itself.
package tailnode

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// The states Status.State takes.
const (
	StateNeedsLogin    = "needs-login"
	StateNeedsApproval = "needs-approval"
	StateStarting      = "starting"
	StateNeedsFunnel   = "needs-funnel"
	StateSettingUp     = "setting-up"
	StateRunning       = "running"
	StateError         = "error"
)

// StartingLimit is how long the node may stay in starting before the state
// becomes an error. A node that is already signed in reaches running within
// seconds, and a first sign-in took under a minute from the sign-up to
// running, so two minutes leaves room for a slow network without leaving a
// stuck start unreported.
const StartingLimit = 2 * time.Minute

// SettingUpLimit is how long the node may stay in setting-up before the state
// becomes an error. The first public answer after Funnel was turned on took
// up to about 100 seconds, most of it the first certificate being issued, so
// three minutes covers the slowest first run seen with a margin and still
// reports a stuck address while a person is looking at the screen.
const SettingUpLimit = 3 * time.Minute

// MaxPublicConns caps the connections open at once on the public listener. A
// follower phone holds one or two, so the cap only ever bites a flood.
const MaxPublicConns = 128

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
}

// State maps an observation to the status to report. It reads no clock and
// does no I/O.
func State(o Observation) Status {
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
	if !o.Listening || !o.PublicAnswered {
		if o.InStateFor >= SettingUpLimit {
			return Status{State: StateError, Error: "Your address did not answer in time. Check your internet connection and try again."}
		}
		return Status{State: StateSettingUp, PublicHost: host}
	}
	return Status{State: StateRunning, PublicHost: host}
}

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
// answers 404 without reaching it.
func PublicHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !publicPath(r.URL.Path) {
			http.NotFound(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

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
