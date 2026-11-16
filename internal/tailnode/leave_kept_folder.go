package tailnode

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

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
