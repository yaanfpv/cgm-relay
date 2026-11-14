package tailnode

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
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
