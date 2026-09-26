// Package relay wires cgm-relay's own pieces together: it signs in to a
// CGM source, runs the minute-by-minute poller against the encrypted
// store, and serves the stored readings over the Nightscout API and a
// local status endpoint, all until its context is cancelled.
package relay

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/config"
	"github.com/yaanfpv/cgm-relay/internal/librelinkup"
	"github.com/yaanfpv/cgm-relay/internal/nightscout"
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

// Addresses reports where Run actually bound its two listeners, which
// matters when a caller configures an ephemeral port ("host:0") rather
// than a fixed one.
type Addresses struct {
	// Nightscout is the address the Nightscout API is reachable at.
	Nightscout string
	// Status is the address the local status endpoint is reachable at.
	Status string
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

// WithReady registers a callback invoked exactly once, after both
// listeners are bound and before Run blocks waiting for ctx. Tests use it
// to learn the actual bound addresses when a config asks for an
// ephemeral port; production code has no need to call it.
func WithReady(fn func(Addresses)) Option {
	return func(st *settings) { st.ready = fn }
}

// Run signs in to the configured CGM account, polls it once a minute, and
// serves the stored readings over the Nightscout API (cfg.ListenAddr) and
// a local status endpoint (cfg.StatusAddr), until ctx is done. It returns
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
		source = librelinkup.New(cfg.LibreLinkUpEmail, cfg.LibreLinkUpPassword)
	}

	retention := time.Duration(cfg.RetentionDays) * 24 * time.Hour
	p := poller.New(source, db, retention)

	nsHandler, err := nightscout.New(db, cfg.Token, nil)
	if err != nil {
		return fmt.Errorf("relay: build nightscout handler: %w", err)
	}

	tracker := newClientTracker()
	nsServer, err := startServer(cfg.ListenAddr, trackClients(nsHandler, tracker, time.Now))
	if err != nil {
		return fmt.Errorf("relay: listen on %s: %w", cfg.ListenAddr, err)
	}
	defer nsServer.shutdown()

	statusServer, err := startServer(cfg.StatusAddr, newStatusHandler(p, tracker))
	if err != nil {
		return fmt.Errorf("relay: listen on %s: %w", cfg.StatusAddr, err)
	}
	defer statusServer.shutdown()

	logger.Printf("serving the Nightscout API on %s", nsServer.addr())
	logger.Printf("serving the status endpoint on %s", statusServer.addr())

	if st.ready != nil {
		st.ready(Addresses{Nightscout: nsServer.addr(), Status: statusServer.addr()})
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

	var runErr error
	select {
	case <-ctx.Done():
		runErr = ctx.Err()
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
	}
	rs := &runningServer{srv: srv, ln: ln, errCh: make(chan error, 1)}
	go func() {
		serveErr := srv.Serve(ln)
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
