package tailnode

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/logtail"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

// stateFileName is the file tsnet keeps a node's saved state in, inside its
// state folder.
const stateFileName = "tailscaled.state"

// LeaveKeptFolder logs out the node that a failed leave kept in stateDir, with
// no engine and no serving: it starts a tsnet node on the folder, asks the
// control server to expire its key, closes the node, and removes the folder
// only after the logout answered. A folder whose saved state holds no node key
// is removed with nothing started, since there is nothing to log out. A logout
// that cannot reach the control server, or is cut short by ctx, closes the
// node, leaves the folder untouched and answers KeptForRetry.
//
// The logout is sent only after the node's own sign-in attempt has settled
// (see signInReceipt), so it never runs alongside a sign-in still in flight;
// when ctx ends first, nothing is sent.
//
// The control server is the one tsnet picks (TS_CONTROL_URL when set). A
// folder whose saved state says logged out makes tsnet start an interactive
// sign-in of its own, and the leave waits for the control server's answer to
// it like any other. One call is one logout attempt: a failed logout
// clears the node's key in memory, so a second attempt belongs in a new
// process.
func LeaveKeptFolder(ctx context.Context, stateDir, hostname string) (LeaveResult, error) {
	if stateDir == "" {
		return KeptForRetry, errors.New("tailnode: no state folder to leave")
	}
	holds, err := stateHoldsNodeKey(stateDir)
	if err != nil {
		return KeptForRetry, err
	}
	if !holds {
		if err := os.RemoveAll(stateDir); err != nil {
			return KeptForRetry, err
		}
		return LeftAndRemoved, nil
	}
	if err := prepareStateDir(stateDir); err != nil {
		return KeptForRetry, err
	}
	prepareNodeEnv()
	s := &tsnet.Server{Dir: stateDir, Hostname: hostname, Logf: logger.Discard, UserLogf: logger.Discard}
	if err := s.Start(); err != nil {
		closeWithin(s, closeTimeout)
		return KeptForRetry, err
	}
	lc, err := s.LocalClient()
	if err != nil {
		closeWithin(s, closeTimeout)
		return KeptForRetry, err
	}
	if err := awaitBusSettled(ctx, lc); err != nil {
		closeWithin(s, closeTimeout)
		return KeptForRetry, err
	}
	if err := lc.Logout(ctx); err != nil {
		closeWithin(s, closeTimeout)
		return KeptForRetry, err
	}
	closeWithin(s, closeTimeout)
	if err := os.RemoveAll(stateDir); err != nil {
		return KeptForRetry, err
	}
	return LeftAndRemoved, nil
}

// awaitBusSettled returns once the node behind lc has reported that its own
// sign-in attempt settled, or an error when ctx ends first.
func awaitBusSettled(ctx context.Context, lc *local.Client) error {
	wctx, cancel := context.WithCancel(ctx)
	w, err := lc.WatchIPNBus(wctx, ipn.NotifyInitialState)
	if err != nil {
		cancel()
		return errors.Join(errSignInNotSettled, err)
	}
	settled := make(chan struct{})
	var receipt signInReceipt
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		for {
			note, err := w.Next()
			if err != nil {
				return
			}
			if receipt.observe(note) {
				close(settled)
				return
			}
		}
	}()
	err = awaitSettled(ctx, settled)
	cancel()
	_ = w.Close()
	<-finished
	return err
}

// closeWithin closes s, waiting at most limit for it: a node whose network is
// gone can take longer, and the caller's process exit ends it.
func closeWithin(s *tsnet.Server, limit time.Duration) {
	done := make(chan struct{})
	go func() { _ = s.Close(); close(done) }()
	t := time.NewTimer(limit)
	defer t.Stop()
	select {
	case <-done:
	case <-t.C:
	}
}

// stateHoldsNodeKey reads the saved state in dir, without starting a node, and
// reports whether any saved profile holds a node key. A missing or empty
// folder or state file holds none.
func stateHoldsNodeKey(dir string) (bool, error) {
	raw, err := os.ReadFile(filepath.Join(dir, stateFileName))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if len(raw) == 0 {
		return false, nil
	}
	var entries map[string][]byte
	if err := json.Unmarshal(raw, &entries); err != nil {
		return false, err
	}
	for _, value := range entries {
		var prefs ipn.Prefs
		if json.Unmarshal(value, &prefs) != nil {
			continue
		}
		if prefs.Persist != nil && !prefs.Persist.PrivateNodeKey.IsZero() {
			return true, nil
		}
	}
	return false, nil
}

// errSignInNotSettled is what a leave reports when its context ended before
// the node's own sign-in attempt settled, so no logout was sent.
var errSignInNotSettled = errors.New("tailnode: the node's sign-in had not settled")

// signInReceipt follows one server's notifications and says when its own
// sign-in attempt has settled: the backend reports Starting, Running or
// NeedsMachineAuth, or NeedsLogin after the control server has sent a sign-in
// URL. NeedsLogin alone is not enough, since a folder saved as logged out
// reports it with no contact with the control server. It relies on the
// network-map cache being off (see prepareNodeEnv): a cached map would report
// Starting before the sign-in is answered.
type signInReceipt struct {
	state   ipn.State
	sawURL  bool
	settled bool
}

// observe takes one notification and reports whether the sign-in has settled.
// Once it has, it stays settled.
func (r *signInReceipt) observe(n ipn.Notify) bool {
	if n.BrowseToURL != nil && *n.BrowseToURL != "" {
		r.sawURL = true
	}
	if n.State != nil {
		r.state = *n.State
	}
	switch r.state {
	case ipn.Starting, ipn.Running, ipn.NeedsMachineAuth:
		r.settled = true
	case ipn.NeedsLogin:
		if r.sawURL {
			r.settled = true
		}
	}
	return r.settled
}

// prepareNodeEnv sets the three process-wide switches every tsnet start needs
// (the network-map cache, port mapping and log uploads), and is called
// before each one. With tailscale's network-map cache off, only the live
// sign-in can report the node as signed in, so a leave can trust the
// state it sees; a cached map would report Starting before the control server
// has answered. Port mapping probes the local network for a router, which
// makes macOS ask the person to allow local network access, and neither
// Funnel nor the public listener uses it. The cache switch is "false" because
// an empty value means on. The node's own logs stay on this Mac: logtail
// would otherwise upload them to Tailscale's log service, so its uploads are
// turned off for the whole process.
func prepareNodeEnv() {
	envknob.Setenv("TS_USE_CACHED_NETMAP", "false")
	envknob.Setenv("TS_DISABLE_PORTMAPPER", "1")
	logtail.Disable()
}

// awaitSettled waits until settled is closed, and fails when ctx ends first.
// The caller's context is the only bound.
func awaitSettled(ctx context.Context, settled <-chan struct{}) error {
	select {
	case <-settled:
		return nil
	case <-ctx.Done():
		select {
		case <-settled:
			return nil
		default:
		}
		return errors.Join(errSignInNotSettled, ctx.Err())
	}
}
