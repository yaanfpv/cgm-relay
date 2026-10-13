// Package relay wires cgm-relay's own pieces together: it signs in to a
// CGM source, runs the minute-by-minute poller against the encrypted
// store, and serves the stored readings over the Nightscout API and a
// local status endpoint, all until its context is cancelled.
package relay

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/config"
	"github.com/yaanfpv/cgm-relay/internal/librelinkup"
	"github.com/yaanfpv/cgm-relay/internal/nightscout"
	"github.com/yaanfpv/cgm-relay/internal/pairing"
	"github.com/yaanfpv/cgm-relay/internal/poller"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// shutdownTimeout bounds how long Run waits for the HTTP servers to
// finish in-flight requests once ctx is done, so a slow client can never
// turn a requested shutdown into a hang.
const shutdownTimeout = 5 * time.Second

// statusLogInterval is how often Run checks the poller's status for a
// message worth logging, such as a sign-in failure starting or clearing.
const statusLogInterval = time.Second

// The following timeouts are applied to both HTTP servers Run starts.
// readHeaderTimeout bounds a slow or stalled client during the request
// line and headers; readTimeout and writeTimeout bound the body and the
// response; idleTimeout bounds how long an idle keep-alive connection is
// held open.
const (
	readHeaderTimeout = 5 * time.Second
	readTimeout       = 10 * time.Second
	writeTimeout      = 10 * time.Second
	idleTimeout       = 60 * time.Second
)

// Addresses reports where Run actually bound its listeners, which
// matters when a caller configures an ephemeral port ("host:0") rather
// than a fixed one.
type Addresses struct {
	// Nightscout is the address the Nightscout API is reachable at.
	Nightscout string
	// Status is the address the local status endpoint is reachable at.
	Status string
	// LAN holds the addresses the TLS listeners cfg.LANListenAddrs asked
	// for are bound to, in the same order.
	LAN []string
}

// Option configures a Run call.
type Option func(*settings)

type settings struct {
	source    cgm.Source
	logOutput io.Writer
	ready     func(Addresses)
}

// WithSource overrides the CGM source Run polls, in place of the
// LibreLinkUp source it would otherwise build from cfg's credentials.
// Tests use it to point Run at an in-process fake server; production
// code has no reason to call it.
func WithSource(s cgm.Source) Option {
	return func(st *settings) { st.source = s }
}

// WithLogOutput overrides where Run's log lines go, in place of
// os.Stderr. Tests use it to capture output and check it never carries a
// secret.
func WithLogOutput(w io.Writer) Option {
	return func(st *settings) { st.logOutput = w }
}

// WithReady registers a callback invoked exactly once, after every
// listener is bound and before Run blocks waiting for ctx. Tests use it
// to learn the actual bound addresses when a config asks for an
// ephemeral port; production code has no need to call it.
func WithReady(fn func(Addresses)) Option {
	return func(st *settings) { st.ready = fn }
}

// ErrPortInUse is wrapped into Run's error when the Nightscout listener
// cannot bind because another program already holds its address. A
// supervising app tells it apart from an ordinary crash by the exit code
// cmd/cgm-relay gives it: restarting loses the same race.
var ErrPortInUse = errors.New("relay: port is in use by another program")

// Run signs in to the configured CGM account, polls it once a minute, and
// serves the stored readings over the Nightscout API (cfg.ListenAddr, plain
// http, and each of cfg.LANListenAddrs, TLS only) and a local status
// endpoint (cfg.StatusAddr), until ctx is done. It returns
// ctx's own error once ctx is done and every component has stopped
// cleanly, or a non-nil error naming whichever piece of the wiring failed
// to start.
func Run(ctx context.Context, cfg config.Config, opts ...Option) error {
	st := &settings{logOutput: os.Stderr}
	for _, opt := range opts {
		opt(st)
	}
	logger := log.New(st.logOutput, "cgm-relay: ", log.LstdFlags)

	if !config.IsLoopbackAddr(cfg.StatusAddr) {
		return fmt.Errorf("relay: status address %q is not loopback-only", cfg.StatusAddr)
	}

	// Refused before the store opens or anything binds, so a bad certificate
	// can never leave a plain-http listener behind. The addresses' own
	// private-IPv4 rule is config.ValidateLANListenAddrs, applied where the
	// configuration is read; Run binds what it is handed.
	lanTLS, err := cfg.LANTLSConfig()
	if err != nil {
		return fmt.Errorf("relay: %w", err)
	}

	if err := ensureDatabaseDir(cfg.DatabasePath); err != nil {
		return err
	}

	db, err := store.Open(ctx, cfg.DatabasePath, cfg.Key)
	if err != nil {
		return fmt.Errorf("relay: open store: %w", err)
	}
	defer db.Close()

	source := st.source
	if source == nil {
		var sourceOpts []librelinkup.Option
		if cfg.LibreLinkUpBaseURL != "" {
			sourceOpts = append(sourceOpts, librelinkup.WithBaseURL(cfg.LibreLinkUpBaseURL))
		}
		source = librelinkup.New(cfg.LibreLinkUpEmail, cfg.LibreLinkUpPassword, sourceOpts...)
	}

	retention := time.Duration(cfg.RetentionDays) * 24 * time.Hour
	p := poller.New(source, db, retention, poller.WithLogger(logger))

	nsHandler, err := nightscout.New(db, cfg.Token, nil)
	if err != nil {
		return fmt.Errorf("relay: build nightscout handler: %w", err)
	}

	tracker := newClientTracker()
	lanReadings := newClientTracker()
	pairings := pairing.NewStore(nil)
	nsAPI := withPairingPage(trackClients(nsHandler, tracker, time.Now), pairings, cfg.Token)
	nsServer, err := startServer(cfg.ListenAddr, nsAPI)
	if err != nil {
		if errors.Is(err, syscall.EADDRINUSE) {
			return fmt.Errorf("relay: listen on %s: %w: %w", cfg.ListenAddr, ErrPortInUse, err)
		}
		return fmt.Errorf("relay: listen on %s: %w", cfg.ListenAddr, err)
	}
	defer nsServer.shutdown()

	lanAPI := trackLANReadings(nsAPI, lanReadings, time.Now)
	var lanServers []*runningServer
	for _, addr := range cfg.LANListenAddrs {
		lan, err := startListening(addr, lanAPI, lanTLS, newLANErrorLog(logger, time.Now))
		if err != nil {
			return fmt.Errorf("relay: listen on %s: %w", addr, err)
		}
		defer lan.shutdown()
		lanServers = append(lanServers, lan)
	}

	statusServer, err := startServer(cfg.StatusAddr, newStatusHandler(p, tracker, lanReadings, pairings, cfg.StatusSecret))
	if err != nil {
		return fmt.Errorf("relay: listen on %s: %w", cfg.StatusAddr, err)
	}
	defer statusServer.shutdown()

	logger.Printf("serving the Nightscout API on %s", nsServer.addr())
	for _, lan := range lanServers {
		logger.Printf("serving the Nightscout API over TLS on %s", lan.addr())
	}
	logger.Printf("serving the status endpoint on %s", statusServer.addr())

	if st.ready != nil {
		addrs := Addresses{Nightscout: nsServer.addr(), Status: statusServer.addr()}
		for _, lan := range lanServers {
			addrs.LAN = append(addrs.LAN, lan.addr())
		}
		st.ready(addrs)
	}

	// runCtx is derived from ctx rather than used interchangeably with it:
	// if a server dies unexpectedly, ctx itself is not done, but the
	// poller and the status watcher still need to be told to stop before
	// this function returns and its deferred db.Close runs -- otherwise
	// the poller goroutine keeps running, and calling Close concurrently
	// with its still-active use of db is exactly the fault this avoids.
	runCtx, cancelRun := context.WithCancel(ctx)
	defer cancelRun()

	pollErr := make(chan error, 1)
	go func() { pollErr <- p.Run(runCtx) }()
	go watchPollerStatus(runCtx, p, logger)

	// A LAN listener that dies is as fatal as the loopback one: the process
	// would otherwise keep running with phones silently unable to connect.
	// Sized for one send per listener, so a second failure never blocks.
	lanErr := make(chan error, len(lanServers))
	for _, lan := range lanServers {
		go func() {
			if err := <-lan.errCh; err != nil {
				lanErr <- err
			}
		}()
	}

	var runErr error
	select {
	case <-ctx.Done():
		runErr = ctx.Err()
	case err := <-lanErr:
		runErr = fmt.Errorf("relay: LAN server stopped: %w", err)
	case err := <-nsServer.errCh:
		if err != nil {
			runErr = fmt.Errorf("relay: nightscout server stopped: %w", err)
		}
	case err := <-statusServer.errCh:
		if err != nil {
			runErr = fmt.Errorf("relay: status server stopped: %w", err)
		}
	}

	cancelRun()
	<-pollErr
	return runErr
}

// ensureDatabaseDir creates the directory holding the reading database,
// at mode 0700 regardless of the process umask, so the encrypted store
// it is about to hold is never created under a group- or world-readable
// directory.
func ensureDatabaseDir(databasePath string) error {
	dir := filepath.Dir(databasePath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("relay: create database directory %s: %w", dir, err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("relay: set permissions on %s: %w", dir, err)
	}
	return nil
}

// watchPollerStatus logs a plain, secret-free line whenever the poller's
// status carries a new error (a sign-in failure starting, a rate limit,
// or a store problem), until ctx is done. poller.Status.LastError is
// documented as secret-free by the poller package itself, so nothing
// here needs to redact it.
func watchPollerStatus(ctx context.Context, p *poller.Poller, logger *log.Logger) {
	var lastLogged string
	t := time.NewTicker(statusLogInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s := p.Status()
			if s.LastError != "" && s.LastError != lastLogged {
				logger.Printf("poller: %s", s.LastError)
			}
			lastLogged = s.LastError
		}
	}
}

// handshakeErrorMarker starts every line net/http writes when a TLS
// handshake fails. The line ends with the remote address, which for a
// listener on the local network is another device's.
const handshakeErrorMarker = "http: TLS handshake error from "

// handshakeReportInterval is the least time between two lines reporting how
// many handshakes failed.
const handshakeReportInterval = time.Minute

// lanErrorWriter is the writer behind the local network servers' error log.
// It drops each failed-handshake line, so a device on the network can not
// put its address in the log or fill it, and passes every other line
// through. It reports the number of dropped lines, without any address, at
// most once per handshakeReportInterval.
type lanErrorWriter struct {
	out *log.Logger
	now func() time.Time

	mu       sync.Mutex
	dropped  int
	reported time.Time
}

func (w *lanErrorWriter) Write(p []byte) (int, error) {
	if !bytes.Contains(p, []byte(handshakeErrorMarker)) {
		return w.out.Writer().Write(p)
	}
	w.mu.Lock()
	w.dropped++
	var count int
	if now := w.now(); w.reported.IsZero() || now.Sub(w.reported) >= handshakeReportInterval {
		count, w.dropped, w.reported = w.dropped, 0, now
	}
	w.mu.Unlock()
	if count > 0 {
		w.out.Printf("%d TLS connections to the local network port did not complete a handshake", count)
	}
	return len(p), nil
}

// newLANErrorLog returns the error log for a local network server, writing
// through out's destination and format.
func newLANErrorLog(out *log.Logger, now func() time.Time) *log.Logger {
	return log.New(&lanErrorWriter{out: out, now: now}, out.Prefix(), out.Flags())
}

// runningServer is one of the two HTTP servers Run starts.
type runningServer struct {
	srv *http.Server
	ln  net.Listener
	// errCh carries the error Serve returned, or nil if it stopped only
	// because shutdown was called; it is always sent to exactly once,
	// and closed right after, so shutdown's own receive never blocks
	// waiting for a second value that will never arrive.
	errCh chan error
}

// startServer binds addr and starts serving handler on it in the
// background, applying the fixed timeouts every server Run starts needs
// (see readHeaderTimeout and its siblings above). It returns once the
// listener is bound, so a caller can learn the actual address
// immediately, including when addr asks for an ephemeral port.
func startServer(addr string, handler http.Handler) (*runningServer, error) {
	return startListening(addr, handler, nil, nil)
}

// startListening is startServer with an optional TLS configuration. A
// non-nil tlsConfig makes the listener speak TLS only: every connection must
// complete a handshake under it, with no plain-http fallback on the same
// port. Nil means plain http. A non-nil errorLog receives the server's own
// connection-level errors, such as an accept failure, in place of the
// process-wide logger.
func startListening(addr string, handler http.Handler, tlsConfig *tls.Config, errorLog *log.Logger) (*runningServer, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		TLSConfig:         tlsConfig,
		ErrorLog:          errorLog,
	}
	rs := &runningServer{srv: srv, ln: ln, errCh: make(chan error, 1)}
	go func() {
		var serveErr error
		if tlsConfig != nil {
			serveErr = srv.ServeTLS(ln, "", "")
		} else {
			serveErr = srv.Serve(ln)
		}
		if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			rs.errCh <- serveErr
		} else {
			rs.errCh <- nil
		}
		close(rs.errCh)
	}()
	return rs, nil
}

// addr returns the address the server actually bound to.
func (rs *runningServer) addr() string {
	return rs.ln.Addr().String()
}

// shutdown gracefully stops rs, waiting up to shutdownTimeout for
// in-flight requests to finish, and waits for its Serve goroutine to
// actually exit before returning so Run never leaves it running past its
// own return.
func (rs *runningServer) shutdown() {
	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	_ = rs.srv.Shutdown(ctx)
	<-rs.errCh
}
