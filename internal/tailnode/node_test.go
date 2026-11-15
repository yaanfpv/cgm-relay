package tailnode

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/net/netmon"
	"tailscale.com/net/portmapper"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/util/eventbus"
)

// portMappingDisabled asks a real tailscale portmapper client to probe and
// reports whether it refused because port mapping is switched off. The
// client's gateway lookup uses a static monitor with no gateway, so a probe
// that is not refused ends without sending a packet.
func portMappingDisabled(t *testing.T) bool {
	t.Helper()
	bus := eventbus.New()
	defer bus.Close()
	c := portmapper.NewClient(portmapper.Config{EventBus: bus, NetMon: netmon.NewStatic()})
	defer c.Close()
	_, err := c.Probe(context.Background())
	return errors.Is(err, portmapper.ErrPortMappingDisabled)
}

// TestBuiltInNodeRunsWithPortMappingDisabled checks that bringing the node
// up switches tailscale's port mapping off, and does it before the node's
// first contact with its control server, so the engine never probes the local
// network for a router to map a port on (which makes macOS ask the person to
// let the app find devices on local networks). The control server is a local
// fake; the node must still come up as far as asking for a sign-in.
func TestBuiltInNodeRunsWithPortMappingDisabled(t *testing.T) {
	// The knob is process-wide, so start from a known unset value and leave
	// it unset for the tests after this one.
	envknob.Setenv("TS_DISABLE_PORTMAPPER", "")
	t.Cleanup(func() { envknob.Setenv("TS_DISABLE_PORTMAPPER", "") })
	if portMappingDisabled(t) {
		t.Fatal("port mapping is already disabled before the node starts; the check cannot tell")
	}

	ctrl := &testcontrol.Server{RequireAuth: true}
	var once sync.Once
	firstContact := make(chan bool, 1)
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		once.Do(func() { firstContact <- portMappingDisabled(t) })
		ctrl.ServeHTTP(w, r)
	}))
	ctrl.HTTPTestServer = hs
	t.Cleanup(hs.Close)

	needsLogin := make(chan struct{})
	var closeNeedsLogin sync.Once
	n := Start(Options{
		StateDir:   filepath.Join(t.TempDir(), "ts"),
		Hostname:   "relay-test",
		Handler:    http.NotFoundHandler(),
		NewServer:  func(h http.Handler) *http.Server { return &http.Server{Handler: h} },
		controlURL: hs.URL,
		Logf: func(format string, args ...any) {
			if len(args) == 1 && args[0] == StateNeedsLogin {
				closeNeedsLogin.Do(func() { close(needsLogin) })
			}
		},
	})
	t.Cleanup(n.Close)

	// hang ceiling only, not an expectation of how long the node takes
	hang := time.After(2 * time.Minute)
	select {
	case off := <-firstContact:
		if !off {
			t.Error("at the node's first contact with its control server, port mapping was still enabled")
		}
	case <-hang:
		t.Fatal("the node never contacted its control server")
	}
	select {
	case <-needsLogin:
	case <-hang:
		t.Fatalf("the node never reached the sign-in state; last status %+v", n.Status())
	}
	if !portMappingDisabled(t) {
		t.Error("with the node up, port mapping is enabled")
	}
	if got := n.Status().State; got != StateNeedsLogin {
		t.Errorf("status state = %q, want %q", got, StateNeedsLogin)
	}
}

// TestRestartKeepsStateDirectory protects the sign-in across a repair: the
// restart that follows an address that stopped answering must bring the
// node up again on the folder that holds its keys, so the person is not
// asked to sign in again and the machine does not appear as a second
// device. The fake control server stops at the sign-in step, so what this
// can show is the folder: the same one is handed to the new server, its
// contents are unchanged, its mode is still 0700 and nothing is created
// beside it. That the node key itself survives a restart needs a signed-in
// node and is covered by the owner's check on a live address.
func TestRestartKeepsStateDirectory(t *testing.T) {
	ctrl := &testcontrol.Server{RequireAuth: true}
	hs := httptest.NewServer(ctrl)
	ctrl.HTTPTestServer = hs
	t.Cleanup(hs.Close)

	parent := t.TempDir()
	dir := filepath.Join(parent, "ts")
	states := make(chan string, 64)
	n := Start(Options{
		StateDir:   dir,
		Hostname:   "relay-test",
		Handler:    http.NotFoundHandler(),
		NewServer:  func(h http.Handler) *http.Server { return &http.Server{Handler: h} },
		controlURL: hs.URL,
		Logf: func(format string, args ...any) {
			if len(args) == 1 {
				if s, ok := args[0].(string); ok {
					select {
					case states <- s:
					default:
					}
				}
			}
		},
	})
	t.Cleanup(n.Close)

	// hang ceiling only, not an expectation of how long the node takes
	hang := time.After(2 * time.Minute)
	waitSignIn := func(what string) {
		t.Helper()
		for {
			select {
			case s := <-states:
				if s == StateNeedsLogin {
					return
				}
			case <-hang:
				t.Fatalf("the node never reached the sign-in state %s; last status %+v", what, n.Status())
			}
		}
	}
	waitSignIn("before the restart")
	before := readDir(t, dir)

	if err := n.Restart(context.Background()); err != nil {
		t.Fatalf("Restart: %v", err)
	}
	waitSignIn("after the restart")

	n.mu.Lock()
	srv := n.srv
	n.mu.Unlock()
	if srv == nil || srv.Dir != dir {
		t.Errorf("the restarted server's folder is %v, want %s", srv, dir)
	}
	after := readDir(t, dir)
	if len(before) == 0 {
		t.Fatal("the state folder was empty before the restart; the check cannot tell")
	}
	if len(after) != len(before) {
		t.Errorf("state folder files %d after, %d before", len(after), len(before))
	}
	for name, b := range before {
		if got, ok := after[name]; !ok || got != b {
			t.Errorf("state file %s changed across the restart", name)
		}
	}
	if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("state folder after the restart: %v, %v; want mode 0700", fi, err)
	}
	if es, err := os.ReadDir(parent); err != nil || len(es) != 1 {
		t.Errorf("the restart left %d entries beside the state folder, want only it (%v)", len(es), err)
	}
}

// readDir returns the content of every file in dir by name.
func readDir(t *testing.T, dir string) map[string]string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	out := map[string]string{}
	for _, e := range es {
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		out[e.Name()] = string(b)
	}
	return out
}
