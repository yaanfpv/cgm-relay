package tailnode

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
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
// (see signInSettled), so it never runs alongside a sign-in still in flight;
// when ctx ends first, nothing is sent.
//
// The control server is the one tsnet picks (TS_CONTROL_URL when set). It
// never starts a sign-in. One call is one logout attempt: a failed logout
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
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		for {
			note, err := w.Next()
			if err != nil {
				return
			}
			if note.State != nil && signInSettled(*note.State) {
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

// signInSettled reports whether state shows that the node's own sign-in
// attempt has finished: the backend has moved to Starting, Running,
// NeedsLogin or NeedsMachineAuth.
func signInSettled(state ipn.State) bool {
	switch state {
	case ipn.Starting, ipn.Running, ipn.NeedsLogin, ipn.NeedsMachineAuth:
		return true
	}
	return false
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
