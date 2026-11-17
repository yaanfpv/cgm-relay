package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/config"
	"github.com/yaanfpv/cgm-relay/internal/librelinkup"
	"github.com/yaanfpv/cgm-relay/internal/librelinkup/llufake"
	"github.com/yaanfpv/cgm-relay/internal/relay"
	"github.com/yaanfpv/cgm-relay/internal/store"
	"tailscale.com/ipn"
	"tailscale.com/net/netns"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// TestUsageListsConfigStdinFlag checks that the usage summary printed
// with no arguments (or an unknown command) mentions --config-stdin, so a
// caller wiring cgm-relay in from a menu bar app can discover the flag
// without reading source.
func TestUsageListsConfigStdinFlag(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	printUsageTo(&buf)
	if !strings.Contains(buf.String(), "--config-stdin") {
		t.Errorf("usage = %q, want it to mention --config-stdin", buf.String())
	}
}

// TestConfigStdinLifelineShutsDownRelay proves the exact mechanism
// runServe wires between --config-stdin and shutdown: config.LoadFromReader
// decodes one object from a pipe that is still open, the relay keeps
// serving while that pipe stays open, and watchStdinForShutdown reacts to
// the pipe closing by cancelling the same context relay.Run is watching --
// the way a caller's own crash or force quit reaches the engine even
// though no signal was ever sent.
func TestConfigStdinLifelineShutsDownRelay(t *testing.T) {
	t.Parallel()
	fake := llufake.New(t)
	readingTime := time.Now().UTC().Truncate(time.Second)
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: readingTime.Format("1/2/2006 3:04:05 PM"),
		ValueInMgPerDl:   133,
		TrendArrow:       3,
	}, nil)

	dbPath := filepath.Join(t.TempDir(), "data", "readings.db")
	stdinJSON := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "leak-check-password-should-never-log",
  "token": "leak-check-token-should-never-log",
  "listen_addr": "127.0.0.1:0",
  "status_addr": "127.0.0.1:0",
  "database_path": %q,
  "retention_days": 15,
  "key": %q
}`, dbPath, base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{'K'}, 32)))

	r, w := io.Pipe()

	decoded := make(chan config.Config, 1)
	decodeErr := make(chan error, 1)
	go func() {
		cfg, err := config.LoadFromReader(r)
		if err != nil {
			decodeErr <- err
			return
		}
		decoded <- cfg
	}()

	if _, err := w.Write([]byte(stdinJSON)); err != nil {
		t.Fatalf("write stdin config: %v", err)
	}

	var cfg config.Config
	select {
	case cfg = <-decoded:
	case err := <-decodeErr:
		t.Fatalf("LoadFromReader: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("LoadFromReader never returned; it must decode one object without waiting for EOF")
	}

	source := librelinkup.New(cfg.LibreLinkUpEmail, cfg.LibreLinkUpPassword, librelinkup.WithBaseURL(fake.URL))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var shutdownLog bytes.Buffer
	watchStdinForShutdown(r, &shutdownLog, cancel)

	ready := make(chan relay.Addresses, 1)
	runErr := make(chan error, 1)
	go func() {
		runErr <- relay.Run(ctx, cfg, relay.WithSource(source), relay.WithReady(func(a relay.Addresses) { ready <- a }))
	}()

	var addrs relay.Addresses
	select {
	case addrs = <-ready:
	case err := <-runErr:
		t.Fatalf("relay.Run returned before becoming ready: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("relay.Run did not become ready within 5s")
	}

	// The relay is still serving while the pipe is open: an ordinary
	// request must succeed, proving the open pipe has not blocked
	// anything and the engine has not shut down on its own.
	statusURL := fmt.Sprintf("http://%s/status", addrs.Status)
	resp, err := http.Get(statusURL)
	if err != nil {
		t.Fatalf("GET %s: %v", statusURL, err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: status = %d, want 200", statusURL, resp.StatusCode)
	}

	start := time.Now()
	if err := w.Close(); err != nil {
		t.Fatalf("close stdin pipe: %v", err)
	}

	select {
	case err := <-runErr:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("relay.Run returned %v, want context.Canceled", err)
		}
		if elapsed := time.Since(start); elapsed > 5*time.Second {
			t.Errorf("relay.Run took %s to stop after the pipe closed, want a few seconds at most", elapsed)
		}
		// Someone who piped a file into --config-stdin needs to be told
		// why the relay stopped, not left with a silent exit.
		if !strings.Contains(shutdownLog.String(), "stdin closed") {
			t.Errorf("shutdown log = %q, want it to say stdin closed", shutdownLog.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("relay.Run did not return within 5s of the stdin pipe closing")
	}
}

// lockedBuffer is a writer the relay's ready callback can write to while the
// test reads it.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// TestServeReadyLine proves --config-stdin writes exactly one "ready" line
// to stdout, only once both listeners are bound, and that a plain serve
// writes nothing to stdout at all.
func TestServeReadyLine(t *testing.T) {
	t.Parallel()
	if opts := serveReadyOptions(false, io.Discard); len(opts) != 0 {
		t.Fatalf("plain serve got %d ready options, want none: its stdout stays empty", len(opts))
	}

	fake := llufake.New(t)
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: time.Now().UTC().Format("1/2/2006 3:04:05 PM"),
		ValueInMgPerDl:   133,
		TrendArrow:       3,
	}, nil)
	cfg := config.Config{
		LibreLinkUpEmail:    "person@example.test",
		LibreLinkUpPassword: "leak-check-password-should-never-log",
		Token:               "leak-check-token-should-never-log",
		ListenAddr:          "127.0.0.1:0",
		StatusAddr:          "127.0.0.1:0",
		DatabasePath:        filepath.Join(t.TempDir(), "readings.db"),
		RetentionDays:       15,
		Key:                 bytes.Repeat([]byte{'Y'}, 32),
	}
	source := librelinkup.New(cfg.LibreLinkUpEmail, cfg.LibreLinkUpPassword, librelinkup.WithBaseURL(fake.URL))

	var stdout lockedBuffer
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	opts := append(serveReadyOptions(true, &stdout), relay.WithSource(source), relay.WithLogOutput(io.Discard))
	runErr := make(chan error, 1)
	go func() { runErr <- relay.Run(ctx, cfg, opts...) }()

	deadline := time.Now().Add(5 * time.Second)
	for stdout.String() == "" {
		select {
		case err := <-runErr:
			t.Fatalf("relay.Run returned before writing the ready line: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("no ready line within 5s of starting")
		}
		time.Sleep(5 * time.Millisecond)
	}

	cancel()
	if err := <-runErr; !errors.Is(err, context.Canceled) {
		t.Fatalf("relay.Run returned %v, want context.Canceled", err)
	}
	if got := stdout.String(); got != "ready\n" {
		t.Errorf("stdout = %q, want exactly one ready line", got)
	}
}

// TestExitCodeForServeErrorDistinguishesStoreKeyMismatch proves the real
// mismatch relay.Run actually returns -- from a database seeded with one
// key and then served with a different one, exactly as a Keychain reset or
// a restored backup would produce -- is reported with an exit code no
// other serve failure uses, and a plain line naming the problem with
// neither key anywhere in it.
func TestExitCodeForServeErrorDistinguishesStoreKeyMismatch(t *testing.T) {
	t.Parallel()
	dbPath := filepath.Join(t.TempDir(), "readings.db")
	right := bytes.Repeat([]byte{'R'}, 32)
	wrong := bytes.Repeat([]byte{'W'}, 32)

	seeded, err := store.Open(context.Background(), dbPath, right)
	if err != nil {
		t.Fatalf("seed store.Open: %v", err)
	}
	if err := seeded.Close(); err != nil {
		t.Fatalf("close seeded store: %v", err)
	}

	cfg := config.Config{
		LibreLinkUpEmail:    "person@example.test",
		LibreLinkUpPassword: "leak-check-password-should-never-log",
		Token:               "leak-check-token-should-never-log",
		ListenAddr:          "127.0.0.1:0",
		StatusAddr:          "127.0.0.1:0",
		DatabasePath:        dbPath,
		RetentionDays:       15,
		Key:                 wrong,
	}
	runErr := relay.Run(context.Background(), cfg)
	if runErr == nil {
		t.Fatal("relay.Run opened the store with the wrong key, want an error")
	}

	var out bytes.Buffer
	code := exitCodeForServeError(&out, runErr)

	if code != exitCodeStoreKeyMismatch {
		t.Errorf("exit code = %d, want %d", code, exitCodeStoreKeyMismatch)
	}
	if code == exitCodeGenericFailure {
		t.Error("must not reuse the generic failure exit code: a caller needs to tell this apart from an ordinary crash")
	}

	got := out.String()
	if !strings.Contains(got, "the saved readings cannot be opened with this key") {
		t.Errorf("stderr = %q, want it to say the saved readings cannot be opened with this key", got)
	}
	for _, secret := range []string{
		string(right), string(wrong),
		base64.StdEncoding.EncodeToString(right), base64.StdEncoding.EncodeToString(wrong),
	} {
		if strings.Contains(got, secret) {
			t.Errorf("stderr = %q, must never contain either key", got)
		}
	}
}

// TestExitCodeForServeErrorDistinguishesStoreInUse proves a second
// process pointed at the same database -- opened by hand here with the
// first Open still held, exactly the race a second copy of the app would
// lose -- is reported with its own exit code and a plain line naming the
// problem in terms of another copy of the app, never "lock" or "flock".
func TestExitCodeForServeErrorDistinguishesStoreInUse(t *testing.T) {
	t.Parallel()
	dbPath := filepath.Join(t.TempDir(), "readings.db")
	key := bytes.Repeat([]byte{'I'}, 32)

	first, err := store.Open(context.Background(), dbPath, key)
	if err != nil {
		t.Fatalf("first store.Open: %v", err)
	}
	defer first.Close()

	cfg := config.Config{
		LibreLinkUpEmail:    "person@example.test",
		LibreLinkUpPassword: "leak-check-password-should-never-log",
		Token:               "leak-check-token-should-never-log",
		ListenAddr:          "127.0.0.1:0",
		StatusAddr:          "127.0.0.1:0",
		DatabasePath:        dbPath,
		RetentionDays:       15,
		Key:                 key,
	}
	runErr := relay.Run(context.Background(), cfg)
	if runErr == nil {
		t.Fatal("relay.Run opened a database another Store already holds, want an error")
	}

	var out bytes.Buffer
	code := exitCodeForServeError(&out, runErr)

	if code != exitCodeStoreInUse {
		t.Errorf("exit code = %d, want %d", code, exitCodeStoreInUse)
	}
	if code == exitCodeGenericFailure || code == exitCodeStoreKeyMismatch {
		t.Error("must not reuse another failure's exit code: a caller needs to tell this apart from every other failure")
	}

	got := out.String()
	if !strings.Contains(got, "already in use by another copy of CGM Relay") {
		t.Errorf("stderr = %q, want it to say the readings are already in use by another copy", got)
	}
	for _, forbidden := range []string{"lock", "flock", string(key)} {
		if strings.Contains(got, forbidden) {
			t.Errorf("stderr = %q, must never contain %q", got, forbidden)
		}
	}
}

// TestExitCodeForServeErrorDistinguishesStoreDamaged proves a readings
// file that exists but cannot be read as a database at all -- random
// bytes, here, the same shape a truncated or corrupted file would take --
// is reported with its own exit code and a plain line, apart from the
// exit code 1 an ordinary crash gets.
func TestExitCodeForServeErrorDistinguishesStoreDamaged(t *testing.T) {
	t.Parallel()
	dbPath := filepath.Join(t.TempDir(), "readings.db")
	if err := os.WriteFile(dbPath, bytes.Repeat([]byte{0xFF}, 512), 0o600); err != nil {
		t.Fatalf("write garbage file: %v", err)
	}

	cfg := config.Config{
		LibreLinkUpEmail:    "person@example.test",
		LibreLinkUpPassword: "leak-check-password-should-never-log",
		Token:               "leak-check-token-should-never-log",
		ListenAddr:          "127.0.0.1:0",
		StatusAddr:          "127.0.0.1:0",
		DatabasePath:        dbPath,
		RetentionDays:       15,
		Key:                 bytes.Repeat([]byte{'D'}, 32),
	}
	runErr := relay.Run(context.Background(), cfg)
	if runErr == nil {
		t.Fatal("relay.Run opened a garbage file as a database, want an error")
	}

	var out bytes.Buffer
	code := exitCodeForServeError(&out, runErr)

	if code != exitCodeStoreDamaged {
		t.Errorf("exit code = %d, want %d", code, exitCodeStoreDamaged)
	}
	if code == exitCodeGenericFailure {
		t.Error("must not reuse the generic failure exit code: a caller needs to tell this apart from an ordinary crash")
	}

	got := out.String()
	if !strings.Contains(got, "the saved readings file is damaged and cannot be read") {
		t.Errorf("stderr = %q, want it to say the saved readings file is damaged", got)
	}
}

// TestExitCodeForServeErrorDistinguishesPortInUse proves a relay asked to
// listen on a follower port another program already holds -- a real
// listener on an OS-assigned port, here -- is reported with its own exit
// code, apart from the exit code 1 an ordinary crash gets, so a supervising
// app does not restart it in a loop.
func TestExitCodeForServeErrorDistinguishesPortInUse(t *testing.T) {
	t.Parallel()
	holder, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("hold a port: %v", err)
	}
	defer holder.Close()

	cfg := config.Config{
		LibreLinkUpEmail:    "person@example.test",
		LibreLinkUpPassword: "leak-check-password-should-never-log",
		Token:               "leak-check-token-should-never-log",
		ListenAddr:          holder.Addr().String(),
		StatusAddr:          "127.0.0.1:0",
		DatabasePath:        filepath.Join(t.TempDir(), "readings.db"),
		RetentionDays:       15,
		Key:                 bytes.Repeat([]byte{'P'}, 32),
	}
	runErr := relay.Run(context.Background(), cfg)
	if runErr == nil {
		t.Fatal("relay.Run listened on a port another listener holds, want an error")
	}

	var out bytes.Buffer
	code := exitCodeForServeError(&out, runErr)
	if code != exitCodePortInUse {
		t.Errorf("exit code = %d, want %d", code, exitCodePortInUse)
	}
	if !strings.Contains(out.String(), "port is in use by another program") {
		t.Errorf("stderr = %q, want it to say the port is in use", out.String())
	}
}

// TestExitCodeForCheckAccountError is a table test of check-account's own
// exit code for every fake account state its own oracle names: a happy
// sign-in, each of LibreLinkUp's rejections, a rate limit, an unreachable
// server, and a plain, unclassified error. Each case runs the real
// librelinkup.Source.CheckAccount against a fake configured for that
// state, then classifies the exact error it returns -- proving the
// classification against the errors CheckAccount can actually produce,
// never a fabricated stand-in for them.
func TestExitCodeForCheckAccountError(t *testing.T) {
	cases := []struct {
		name         string
		configure    func(fake *llufake.Server) string // returns the base URL to use
		wantCode     int
		wantContains string
	}{
		{
			name: "signed in and follows someone",
			configure: func(fake *llufake.Server) string {
				return fake.URL
			},
			wantCode: 0,
		},
		{
			name: "email or password rejected",
			configure: func(fake *llufake.Server) string {
				fake.RejectCredentials()
				return fake.URL
			},
			wantCode:     exitCodeAccountRejected,
			wantContains: "rejected the email or password",
		},
		{
			name: "updated terms not accepted",
			configure: func(fake *llufake.Server) string {
				fake.RequireTermsAcceptance()
				return fake.URL
			},
			wantCode:     exitCodeAccountTermsNotAccepted,
			wantContains: "updated terms accepted",
		},
		{
			name: "account follows nobody",
			configure: func(fake *llufake.Server) string {
				fake.SetConnections()
				return fake.URL
			},
			wantCode:     exitCodeAccountNoConnections,
			wantContains: "follows nobody",
		},
		{
			name: "rate limited",
			configure: func(fake *llufake.Server) string {
				fake.RateLimitLogin("3")
				return fake.URL
			},
			wantCode:     exitCodeAccountRateLimited,
			wantContains: "rate limiting",
		},
		{
			name: "fake mode reject",
			configure: func(fake *llufake.Server) string {
				_ = fake.SetMode("reject")
				return fake.URL
			},
			wantCode:     exitCodeAccountRejected,
			wantContains: "rejected the email or password",
		},
		{
			name: "fake mode terms",
			configure: func(fake *llufake.Server) string {
				_ = fake.SetMode("terms")
				return fake.URL
			},
			wantCode:     exitCodeAccountTermsNotAccepted,
			wantContains: "updated terms accepted",
		},
		{
			name: "fake mode noconnections",
			configure: func(fake *llufake.Server) string {
				_ = fake.SetMode("noconnections")
				return fake.URL
			},
			wantCode:     exitCodeAccountNoConnections,
			wantContains: "follows nobody",
		},
		{
			name: "fake mode ratelimited",
			configure: func(fake *llufake.Server) string {
				_ = fake.SetMode("ratelimited")
				return fake.URL
			},
			wantCode:     exitCodeAccountRateLimited,
			wantContains: "rate limiting",
		},
		{
			name: "fake mode unrecognised sign-in status",
			configure: func(fake *llufake.Server) string {
				_ = fake.SetMode("unrecognised")
				return fake.URL
			},
			wantCode:     exitCodeGenericFailure,
			wantContains: "carried no user id or token",
		},
		{
			name: "unreachable",
			configure: func(fake *llufake.Server) string {
				baseURL := fake.URL
				fake.Close()
				return baseURL
			},
			wantCode:     exitCodeAccountUnreachable,
			wantContains: "could not reach",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fake := llufake.New(t)
			baseURL := c.configure(fake)
			source := librelinkup.New("person@example.test", "leak-check-password-should-never-log", librelinkup.WithBaseURL(baseURL))

			var out bytes.Buffer
			code := exitCodeForCheckAccountError(&out, source.CheckAccount(context.Background()))

			if code != c.wantCode {
				t.Errorf("exit code = %d, want %d (stderr: %q)", code, c.wantCode, out.String())
			}
			if c.wantContains != "" && !strings.Contains(out.String(), c.wantContains) {
				t.Errorf("stderr = %q, want it to contain %q", out.String(), c.wantContains)
			}
			if strings.Contains(out.String(), "leak-check-password-should-never-log") {
				t.Errorf("stderr = %q, must never contain the password", out.String())
			}
		})
	}
}

// TestExitCodeForCheckAccountErrorKeepsGenericFailuresAtOne proves an
// error check-account does not otherwise recognise keeps the plain
// fallback: exit code 1, and the error's own text on stderr, exactly like
// exitCodeForServeError's own equivalent case.
func TestExitCodeForCheckAccountErrorKeepsGenericFailuresAtOne(t *testing.T) {
	var out bytes.Buffer
	original := errors.New("librelinkup: sign-in response carried no user id or token")

	code := exitCodeForCheckAccountError(&out, original)

	if code != exitCodeGenericFailure {
		t.Errorf("exit code = %d, want %d for an unclassified failure", code, exitCodeGenericFailure)
	}
	if !strings.Contains(out.String(), original.Error()) {
		t.Errorf("stderr = %q, want it to contain %q", out.String(), original.Error())
	}
}

// TestUsageMentionsCheckAccount checks that the usage summary mentions
// check-account, so a caller wiring cgm-relay in from a menu bar app can
// discover the command without reading source.
func TestUsageMentionsCheckAccount(t *testing.T) {
	var buf bytes.Buffer
	printUsageTo(&buf)
	if !strings.Contains(buf.String(), "check-account") {
		t.Errorf("usage = %q, want it to mention check-account", buf.String())
	}
}

// TestExitCodeForServeErrorKeepsGenericFailuresAtOne proves every serve
// failure exitCodeForServeError does not specifically recognise keeps
// today's plain behaviour: exit code 1, and the error's own text on
// stderr.
func TestExitCodeForServeErrorKeepsGenericFailuresAtOne(t *testing.T) {
	t.Parallel()
	var out bytes.Buffer
	original := errors.New("relay: listen on 127.0.0.1:1337: address already in use")

	code := exitCodeForServeError(&out, original)

	if code != 1 {
		t.Errorf("exit code = %d, want 1 for an ordinary failure", code)
	}
	if !strings.Contains(out.String(), original.Error()) {
		t.Errorf("stderr = %q, want it to contain %q", out.String(), original.Error())
	}
}

// leaveHangCeiling only ends a leave-tailnet test that waits for something
// that never comes.
const leaveHangCeiling = 2 * time.Minute

// leaveControl is Tailscale's own fake control server (testcontrol) on
// loopback, with a hook that records the register requests a node makes: a
// register request whose expiry is already past is a logout.
type leaveControl struct {
	t    *testing.T
	ctrl *testcontrol.Server
	addr string

	mu       sync.Mutex
	hs       *httptest.Server
	contacts int
	logins   []key.NodePublic
	logouts  []key.NodePublic
}

func newLeaveControl(t *testing.T) *leaveControl {
	t.Helper()
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	c := &leaveControl{t: t}
	c.ctrl = &testcontrol.Server{
		DNSConfig:      &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain: "tail-scale.ts.net",
		MaybeRejectRequest: func(req *http.Request) (int, string, string) {
			if req.URL.Path != "/machine/register" || req.Body == nil {
				return 0, "", ""
			}
			body, err := io.ReadAll(req.Body)
			req.Body = io.NopCloser(bytes.NewReader(body))
			var rr tailcfg.RegisterRequest
			if err != nil || json.Unmarshal(body, &rr) != nil {
				return 0, "", ""
			}
			c.mu.Lock()
			defer c.mu.Unlock()
			c.contacts++
			if !rr.Expiry.IsZero() && rr.Expiry.Before(time.Now()) {
				c.logouts = append(c.logouts, rr.NodeKey)
			} else if !slices.Contains(c.logins, rr.NodeKey) {
				c.logins = append(c.logins, rr.NodeKey)
			}
			return 0, "", ""
		},
	}
	c.up()
	t.Cleanup(c.down)
	return c
}

func (c *leaveControl) up() {
	c.t.Helper()
	listen := "127.0.0.1:0"
	if c.addr != "" {
		listen = c.addr
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		c.t.Fatalf("control server cannot listen on %s: %v", listen, err)
	}
	hs := httptest.NewUnstartedServer(c.ctrl)
	hs.Listener.Close()
	hs.Listener = ln
	hs.Start()
	c.ctrl.HTTPTestServer = hs
	c.mu.Lock()
	c.hs = hs
	c.addr = ln.Addr().String()
	c.mu.Unlock()
}

func (c *leaveControl) down() {
	c.mu.Lock()
	hs := c.hs
	c.hs = nil
	c.mu.Unlock()
	if hs != nil {
		hs.CloseClientConnections()
		hs.Close()
	}
}

func (c *leaveControl) url() string { return "http://" + c.addr }

func (c *leaveControl) counts() (contacts int, logins, logouts []key.NodePublic) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.contacts, slices.Clone(c.logins), slices.Clone(c.logouts)
}

// loginNode signs a real tsnet node in to the fake control server on dir and
// closes it, leaving the folder a built-in route leaves behind.
func (c *leaveControl) loginNode(dir string) key.NodePublic {
	c.t.Helper()
	s := &tsnet.Server{Dir: dir, Hostname: "relay-test", ControlURL: c.url(), Logf: logger.Discard, UserLogf: logger.Discard}
	ctx, cancel := context.WithTimeout(context.Background(), leaveHangCeiling)
	defer cancel()
	if err := waitSignedIn(ctx, s); err != nil {
		_ = s.Close()
		c.t.Fatalf("the node never signed in to the fake control server: %v", err)
	}
	if err := s.Close(); err != nil {
		c.t.Fatalf("closing the signed-in node: %v", err)
	}
	_, logins, _ := c.counts()
	if len(logins) != 1 {
		c.t.Fatalf("the control server registered %d node keys, want 1", len(logins))
	}
	return logins[0]
}

// waitSignedIn returns once the node has been accepted by the control server
// and has its first network map. The fake control server has no relay, so the
// node never reaches Running; Starting is as far as it goes.
func waitSignedIn(ctx context.Context, s *tsnet.Server) error {
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	w, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		return err
	}
	defer w.Close()
	for {
		n, err := w.Next()
		if err != nil {
			return err
		}
		if st := n.State; st != nil && (*st == ipn.Starting || *st == ipn.Running) {
			return nil
		}
	}
}

var (
	leaveBinOnce sync.Once
	leaveBinPath string
	leaveBinErr  error
)

// leaveBinary builds the real cgm-relay command once for the package's tests.
func leaveBinary(t *testing.T) string {
	t.Helper()
	leaveBinOnce.Do(func() {
		dir, err := os.MkdirTemp("", "cgm-relay-leave-bin")
		if err != nil {
			leaveBinErr = err
			return
		}
		leaveBinPath = filepath.Join(dir, "cgm-relay")
		ctx, cancel := context.WithTimeout(context.Background(), leaveHangCeiling)
		defer cancel()
		out, err := exec.CommandContext(ctx, "go", "build", "-o", leaveBinPath, ".").CombinedOutput()
		if err != nil {
			leaveBinErr = fmt.Errorf("go build: %v\n%s", err, out)
		}
	})
	if leaveBinErr != nil {
		t.Fatalf("cannot build the command: %v", leaveBinErr)
	}
	return leaveBinPath
}

// runLeaveTailnet runs `cgm-relay leave-tailnet --config-stdin` with stdin as
// given. Its whole environment is the control server address and a scratch
// HOME: no LibreLinkUp, token, store key or config file is present.
func runLeaveTailnet(t *testing.T, stdin, controlURL string) (exit int, stderr string) {
	t.Helper()
	bin := leaveBinary(t)
	ctx, cancel := context.WithTimeout(context.Background(), leaveHangCeiling)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "leave-tailnet", "--config-stdin")
	cmd.Dir = t.TempDir()
	cmd.Env = []string{"HOME=" + t.TempDir(), "TS_CONTROL_URL=" + controlURL}
	cmd.Stdin = strings.NewReader(stdin)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	cmd.WaitDelay = 10 * time.Second
	err := cmd.Run()
	if ctx.Err() != nil {
		t.Fatalf("leave-tailnet did not exit; stderr: %s", errb.String())
	}
	if err == nil {
		return 0, errb.String()
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		t.Fatalf("leave-tailnet did not run: %v", err)
	}
	return ee.ExitCode(), errb.String()
}

func leaveStdin(dir string) string {
	b, _ := json.Marshal(map[string]string{"tailscale_state_dir": dir, "tailscale_hostname": "relay-test"})
	return string(b)
}

// TestLeaveTailnetCommandLogsOutAndRemovesTheFolder protects the person's
// Tailscale account when the engine cannot start: the subcommand the menu bar
// app runs for a pending leave logs the folder's node key out, removes the
// folder and exits 0, with nothing about LibreLinkUp in its environment.
func TestLeaveTailnetCommandLogsOutAndRemovesTheFolder(t *testing.T) {
	ctrl := newLeaveControl(t)
	dir := filepath.Join(t.TempDir(), "ts")
	nodeKey := ctrl.loginNode(dir)

	exit, stderr := runLeaveTailnet(t, leaveStdin(dir), ctrl.url())
	if exit != 0 {
		t.Fatalf("exit %d, want 0 (logged out and removed); stderr: %s", exit, stderr)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("the state folder is still there after exit 0: %v", err)
	}
	if _, _, out := ctrl.counts(); !slices.Equal(out, []key.NodePublic{nodeKey}) {
		t.Errorf("the control server saw logouts for %v, want one, for %v", out, nodeKey)
	}
}

// TestLeaveTailnetCommandExitsThreeAndKeepsTheFolderWhenControlIsAway is the
// offline Mac: the logout cannot reach Tailscale, so the command exits 3 and
// the folder with its key is untouched for the next launch to retry.
func TestLeaveTailnetCommandExitsThreeAndKeepsTheFolderWhenControlIsAway(t *testing.T) {
	ctrl := newLeaveControl(t)
	dir := filepath.Join(t.TempDir(), "ts")
	ctrl.loginNode(dir)
	before, err := os.ReadFile(filepath.Join(dir, "tailscaled.state"))
	if err != nil || len(before) == 0 {
		t.Fatalf("the signed-in folder has no state file: %v", err)
	}
	ctrl.down()

	exit, stderr := runLeaveTailnet(t, leaveStdin(dir), ctrl.url())
	if exit != 3 {
		t.Fatalf("exit %d, want 3 (kept for retry); stderr: %s", exit, stderr)
	}
	after, err := os.ReadFile(filepath.Join(dir, "tailscaled.state"))
	if err != nil || len(after) == 0 {
		t.Errorf("the key file is gone or empty after a failed logout: %v", err)
	}
}

// TestLeaveTailnetCommandRefusesBadConfigBeforeAnythingStarts protects the
// folder from a request that names no folder, or names one with more than the
// two fields: each exits 2, the control server is never contacted and a real
// folder named beside the bad field is untouched.
func TestLeaveTailnetCommandRefusesBadConfigBeforeAnythingStarts(t *testing.T) {
	ctrl := newLeaveControl(t)
	dir := filepath.Join(t.TempDir(), "ts")
	ctrl.loginNode(dir)
	contactsBefore, _, _ := ctrl.counts()
	state := func() string {
		b, err := os.ReadFile(filepath.Join(dir, "tailscaled.state"))
		if err != nil {
			t.Fatalf("the signed-in folder lost its state file: %v", err)
		}
		return string(b)
	}
	folderBefore := state()

	cases := map[string]string{
		"missing state dir": `{"tailscale_hostname":"relay-test"}`,
		"empty state dir":   `{"tailscale_state_dir":"","tailscale_hostname":"relay-test"}`,
		"unknown field":     fmt.Sprintf(`{"tailscale_state_dir":%q,"tailscale_hostname":"relay-test","librelinkup_email":"person@example.test"}`, dir),
		"not json":          `leave please`,
		"empty stdin":       ``,
		"empty object":      `{}`,
	}
	for name, stdin := range cases {
		t.Run(name, func(t *testing.T) {
			exit, stderr := runLeaveTailnet(t, stdin, ctrl.url())
			if exit != 2 {
				t.Errorf("exit %d, want 2 (bad or missing config); stderr: %s", exit, stderr)
			}
		})
	}
	if contactsAfter, _, out := ctrl.counts(); contactsAfter != contactsBefore || len(out) != 0 {
		t.Errorf("a refused request reached the control server: %d register requests before, %d after, logouts %v", contactsBefore, contactsAfter, out)
	}
	if state() != folderBefore {
		t.Errorf("a refused request changed the node's state file")
	}
}

// TestLeaveTailnetCommandLeavesNoNodeLogsInTheKeptFolder protects the person's
// node logs: the built leave child must not buffer Tailscale log entries,
// because the buffers in the state folder are what gets uploaded to Tailscale's
// log service. The control server is away so the folder is kept and can be
// inspected; each buffer must be absent or empty.
func TestLeaveTailnetCommandLeavesNoNodeLogsInTheKeptFolder(t *testing.T) {
	ctrl := newLeaveControl(t)
	dir := filepath.Join(t.TempDir(), "ts")
	ctrl.loginNode(dir)
	ctrl.down()

	exit, stderr := runLeaveTailnet(t, leaveStdin(dir), ctrl.url())
	if exit != 3 {
		t.Fatalf("exit %d, want 3 (kept for retry); stderr: %s", exit, stderr)
	}
	for _, name := range []string{"tailscaled.log1.txt", "tailscaled.log2.txt"} {
		fi, err := os.Stat(filepath.Join(dir, name))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatalf("stat %s: %v", name, err)
		}
		if fi.Size() != 0 {
			b, _ := os.ReadFile(filepath.Join(dir, name))
			t.Errorf("%s holds %d bytes of log entries after the leave run, want none; first bytes: %.200s", name, fi.Size(), b)
		}
	}
}
