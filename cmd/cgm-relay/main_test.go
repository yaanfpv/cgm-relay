package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/config"
	"github.com/yaanfpv/cgm-relay/internal/librelinkup"
	"github.com/yaanfpv/cgm-relay/internal/librelinkup/llufake"
	"github.com/yaanfpv/cgm-relay/internal/relay"
	"github.com/yaanfpv/cgm-relay/internal/store"
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
