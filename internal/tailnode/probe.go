package tailnode

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"syscall"
	"time"
)

// ProbeClass is the verdict of one test of the public address, or of the
// node check made before it.
type ProbeClass int

const (
	// ProbeOK is an answer to the request.
	ProbeOK ProbeClass = iota
	// ProbeTailnetAddress is a name that resolved inside 100.64.0.0/10, which
	// is the tailnet and not the internet: neither a success nor a failure.
	ProbeTailnetAddress
	// The route's failures: a connection was made and then it broke.
	ProbeRouteDropped
	ProbeRouteTLS
	ProbeRouteServerError
	// ProbeNameNotPublished is a public name that does not exist in DNS. Before
	// the address has answered it is only a name that is still being
	// published; after, it is the route's failure.
	ProbeNameNotPublished
	// The Mac's failures: no connection was made.
	ProbeMacDNS
	ProbeMacNoRoute
	ProbeMacRefused
	ProbeMacTimeout
	// The node's own failures, which a test of the route cannot be trusted
	// through.
	ProbeNodeOffline
	ProbeNodeHealth
	ProbeStatusRead
)

var probeNames = map[ProbeClass]string{
	ProbeOK:               "ok",
	ProbeTailnetAddress:   "tailnet_address",
	ProbeRouteDropped:     "dropped_during_tls",
	ProbeRouteTLS:         "tls_failure",
	ProbeRouteServerError: "server_error",
	ProbeNameNotPublished: "name_not_published",
	ProbeMacDNS:           "dns_failure",
	ProbeMacNoRoute:       "no_route",
	ProbeMacRefused:       "connect_refused",
	ProbeMacTimeout:       "connect_timeout",
	ProbeNodeOffline:      "node_offline",
	ProbeNodeHealth:       "node_unhealthy",
	ProbeStatusRead:       "status_read_failed",
}

// String is the name the class is counted and reported under.
func (c ProbeClass) String() string { return probeNames[c] }

// RouteFailure reports a failure of the public route itself.
func (c ProbeClass) RouteFailure() bool {
	return c == ProbeRouteDropped || c == ProbeRouteTLS || c == ProbeRouteServerError || c == ProbeNameNotPublished
}

// MacSide reports a failure before a connection was made.
func (c ProbeClass) MacSide() bool {
	return c == ProbeMacDNS || c == ProbeMacNoRoute || c == ProbeMacRefused || c == ProbeMacTimeout
}

// NodeSide reports a failure of the node check.
func (c ProbeClass) NodeSide() bool {
	return c == ProbeNodeOffline || c == ProbeNodeHealth || c == ProbeStatusRead
}

var tailnetRange = netip.MustParsePrefix("100.64.0.0/10")

// IsTailnetAddress reports whether a is in 100.64.0.0/10.
func IsTailnetAddress(a netip.Addr) bool { return tailnetRange.Contains(a.Unmap()) }

// ClassifyProbe maps what a request returned to its class. Only a failure
// after a connection was made is the route's: a name that does not resolve, no
// route, a refusal or a timeout before the connection are the Mac's.
func ClassifyProbe(status int, err error) ProbeClass {
	if err == nil {
		if status == http.StatusOK {
			return ProbeOK
		}
		return ProbeRouteServerError
	}
	var dns *net.DNSError
	if errors.As(err, &dns) {
		// A name that does not exist is the address's; a resolver that cannot
		// be reached is the Mac's.
		if dns.IsNotFound {
			return ProbeNameNotPublished
		}
		return ProbeMacDNS
	}
	var (
		unknown  x509.UnknownAuthorityError
		invalid  x509.CertificateInvalidError
		hostname x509.HostnameError
		verify   *tls.CertificateVerificationError
		record   tls.RecordHeaderError
	)
	if errors.As(err, &unknown) || errors.As(err, &invalid) || errors.As(err, &hostname) ||
		errors.As(err, &verify) || errors.As(err, &record) {
		return ProbeRouteTLS
	}
	switch {
	case errors.Is(err, syscall.ECONNREFUSED):
		return ProbeMacRefused
	case errors.Is(err, syscall.EHOSTUNREACH), errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.ENETDOWN):
		return ProbeMacNoRoute
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF),
		errors.Is(err, syscall.ECONNRESET), errors.Is(err, syscall.EPIPE):
		return ProbeRouteDropped
	}
	msg := err.Error()
	if strings.Contains(msg, "TLS handshake timeout") {
		return ProbeRouteDropped
	}
	if strings.Contains(msg, "tls:") {
		return ProbeRouteTLS
	}
	var op *net.OpError
	dialing := errors.As(err, &op) && op.Op == "dial"
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		if dialing {
			return ProbeMacTimeout
		}
		return ProbeRouteDropped
	}
	if dialing {
		return ProbeMacNoRoute
	}
	return ProbeRouteDropped
}

// probeDialTimeout bounds the connection step of one test, so a connection
// that never opens is told apart from one that opened and then stalled.
const probeDialTimeout = 10 * time.Second

// NewPublicProbe returns the test of the public address that production runs.
// The request goes through this machine's own network and resolver, not the
// node's dialer, so it travels the route a phone's request travels. A name
// that resolves only into the tailnet's range is reported as such and never
// connected to, since reaching it would test the tailnet and not the internet.
func NewPublicProbe() ProbeFunc {
	return func(ctx context.Context, host string) ProbeClass {
		name := host
		if h, _, err := net.SplitHostPort(host); err == nil {
			name = h
		}
		ips, err := resolve(ctx, name)
		if err != nil {
			return ClassifyProbe(0, err)
		}
		outside := false
		for _, a := range ips {
			if !IsTailnetAddress(a) {
				outside = true
			}
		}
		if !outside {
			return ProbeTailnetAddress
		}
		dialer := &net.Dialer{
			Timeout: probeDialTimeout,
			// A name that answers with both kinds of address is dialled on
			// the outside ones only.
			Control: func(_, address string, _ syscall.RawConn) error {
				if ap, err := netip.ParseAddrPort(address); err == nil && IsTailnetAddress(ap.Addr()) {
					return &net.AddrError{Err: "address is inside the tailnet range", Addr: address}
				}
				return nil
			},
		}
		client := &http.Client{
			Timeout: publicAttemptTimeout,
			Transport: &http.Transport{
				DisableKeepAlives:   true,
				TLSHandshakeTimeout: publicAttemptTimeout,
				DialContext:         dialer.DialContext,
			},
		}
		defer client.CloseIdleConnections()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+host+publicCheckPath, nil)
		if err != nil {
			return ProbeRouteDropped
		}
		resp, err := client.Do(req)
		if err != nil {
			return ClassifyProbe(0, err)
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
		return ClassifyProbe(resp.StatusCode, nil)
	}
}

// resolve looks name up with the machine's own resolver. A literal address is
// returned as it is.
func resolve(ctx context.Context, name string) ([]netip.Addr, error) {
	if a, err := netip.ParseAddr(name); err == nil {
		return []netip.Addr{a}, nil
	}
	return net.DefaultResolver.LookupNetIP(ctx, "ip", name)
}
