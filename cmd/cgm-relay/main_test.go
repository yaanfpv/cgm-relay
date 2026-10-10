package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
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

// The LAN listener tests below drive the same path `serve --config-stdin`
// does: config.LoadFromReader decodes and validates the stdin object, then
// relay.Run binds. A CI machine has no guaranteed private IPv4 interface, so
// a test that has to actually serve takes the config LoadFromReader returned
// for a private address and rebinds the listener to 127.0.0.1 before Run
// (the private-address rule itself is exercised on the stdin path, where
// nothing ever binds). The certificate names 127.0.0.1 and lanTestName, and
// the name-mapping client resolves lanTestName with a custom dialer; no
// mDNS is involved.

const (
	lanTestName    = "cgm-relay.test"
	lanTestPrivate = "192.168.77.20:8443"
	lanTestToken   = "lan-token-for-tests"
)

// testPKI is a throwaway certificate authority and one leaf it issued.
type testPKI struct {
	roots   *x509.CertPool
	certPEM string
	keyPEM  string
	keyDER  []byte
}

// newTestPKI issues a P-256 leaf valid for 127.0.0.1 and lanTestName under a
// fresh CA. Every call yields a distinct private key.
func newTestPKI(t *testing.T) testPKI {
	t.Helper()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "cgm-relay test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create CA certificate: %v", err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatalf("parse CA certificate: %v", err)
	}

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: lanTestName},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{lanTestName},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create leaf certificate: %v", err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(leafKey)
	if err != nil {
		t.Fatalf("marshal leaf key: %v", err)
	}

	roots := x509.NewCertPool()
	roots.AddCert(caCert)
	return testPKI{
		roots:   roots,
		certPEM: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER})),
		keyPEM:  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})),
		keyDER:  keyDER,
	}
}

// assertNoKeyMaterial fails if out carries the private key in PEM, raw DER
// or any base64 form, whole or as a 24-character run of its encoding.
func assertNoKeyMaterial(t *testing.T, label, out string, k testPKI) {
	t.Helper()
	if strings.Contains(out, k.keyPEM) || strings.Contains(out, "PRIVATE KEY") {
		t.Errorf("%s carries PEM key material: %q", label, out)
	}
	if bytes.Contains([]byte(out), k.keyDER) {
		t.Errorf("%s carries the raw DER private key", label)
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		encoded := enc.EncodeToString(k.keyDER)
		for i := 0; i+24 <= len(encoded); i++ {
			if strings.Contains(out, encoded[i:i+24]) {
				t.Errorf("%s carries base64 key material (%s)", label, encoded[i:i+24])
				return
			}
		}
	}
}

func freeLoopbackAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve a port: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	return addr
}

// assertNothingListening fails if addr accepts a connection.
func assertNothingListening(t *testing.T, addr string) {
	t.Helper()
	conn, err := net.DialTimeout("tcp", addr, time.Second)
	if err == nil {
		conn.Close()
		t.Errorf("%s accepts connections after a refusal, want nothing bound", addr)
	}
}

// lanStdin renders a stdin config object for the LAN tests. fields are
// merged over the base so a case can override or add any key.
func lanStdin(t *testing.T, fields map[string]any) string {
	t.Helper()
	obj := map[string]any{
		"librelinkup_email":    "person@example.test",
		"librelinkup_password": "leak-check-password-should-never-log",
		"token":                lanTestToken,
		"listen_addr":          "127.0.0.1:0",
		"status_addr":          "127.0.0.1:0",
		"database_path":        filepath.Join(t.TempDir(), "data", "readings.db"),
		"retention_days":       15,
		"key":                  base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{'L'}, 32)),
	}
	for k, v := range fields {
		obj[k] = v
	}
	b, err := json.Marshal(obj)
	if err != nil {
		t.Fatalf("marshal stdin config: %v", err)
	}
	return string(b)
}

// serveStdin runs what `serve --config-stdin` runs for a stdin object, with
// its two output streams captured. It returns when Run does, or when ctx is
// done.
func serveStdin(ctx context.Context, stdin string, stdout, stderr io.Writer, opts ...relay.Option) {
	cfg, err := config.LoadFromReader(strings.NewReader(stdin))
	if err != nil {
		fmt.Fprintf(stderr, "cgm-relay: serve: %v\n", err)
		return
	}
	runLAN(ctx, cfg, stdout, stderr, opts...)
}

// runLAN runs relay.Run as runServe does under --config-stdin, with stdout
// and stderr captured. A caller that passes its own relay.WithReady takes
// over the ready line's place and must write readyLine itself.
func runLAN(ctx context.Context, cfg config.Config, stdout, stderr io.Writer, opts ...relay.Option) {
	opts = append(serveReadyOptions(true, stdout), opts...)
	opts = append(opts, relay.WithLogOutput(stderr))
	if err := relay.Run(ctx, cfg, opts...); err != nil && !errors.Is(err, context.Canceled) {
		exitCodeForServeError(stderr, err)
	}
}

// lanRelay is a running relay with one TLS listener on loopback.
type lanRelay struct {
	addrs  relay.Addresses
	stdout *lockedBuffer
	stderr *lockedBuffer
	stop   func()
}

// startLANRelay serves the synthetic readings in fake through a relay whose
// LAN listener is bound on loopback with pki's leaf.
func startLANRelay(t *testing.T, pki testPKI, fake *llufake.Server) *lanRelay {
	t.Helper()
	cfg, err := config.LoadFromReader(strings.NewReader(lanStdin(t, map[string]any{
		"lan_listen_addrs": []string{lanTestPrivate},
		"tls_cert_pem":     pki.certPEM,
		"tls_key_pem":      pki.keyPEM,
	})))
	if err != nil {
		t.Fatalf("LoadFromReader: %v", err)
	}
	cfg.LANListenAddrs = []string{"127.0.0.1:0"}
	source := librelinkup.New(cfg.LibreLinkUpEmail, cfg.LibreLinkUpPassword, librelinkup.WithBaseURL(fake.URL))

	r := &lanRelay{stdout: &lockedBuffer{}, stderr: &lockedBuffer{}}
	ctx, cancel := context.WithCancel(context.Background())
	ready := make(chan relay.Addresses, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		runLAN(ctx, cfg, r.stdout, r.stderr, relay.WithSource(source), relay.WithReady(func(a relay.Addresses) {
			_, _ = io.WriteString(r.stdout, readyLine)
			ready <- a
		}))
	}()
	r.stop = func() {
		cancel()
		<-done
	}
	t.Cleanup(r.stop)
	select {
	case r.addrs = <-ready:
	case <-done:
		t.Fatalf("relay stopped before becoming ready: %s", r.stderr.String())
	case <-time.After(5 * time.Second):
		t.Fatal("relay did not become ready within 5s")
	}
	if len(r.addrs.LAN) != 1 {
		t.Fatalf("LAN addresses = %v, want exactly one", r.addrs.LAN)
	}
	return r
}

func lanFake(t *testing.T) *llufake.Server {
	t.Helper()
	fake := llufake.New(t)
	now := time.Now().UTC().Truncate(time.Second)
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: now.Format("1/2/2006 3:04:05 PM"),
		ValueInMgPerDl:   133,
		TrendArrow:       3,
	}, []llufake.Measurement{{
		FactoryTimestamp: now.Add(-5 * time.Minute).Format("1/2/2006 3:04:05 PM"),
		ValueInMgPerDl:   121,
		TrendArrow:       3,
	}})
	return fake
}

// readSgvs polls url with client until it serves entries, and returns their
// sgv values newest first.
func readSgvs(t *testing.T, client *http.Client, url string) []int {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		resp, err := client.Get(url)
		if err != nil {
			t.Fatalf("GET %s: %v", url, err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: status = %d, body = %s", url, resp.StatusCode, body)
		}
		var entries []struct {
			Sgv int `json:"sgv"`
		}
		if err := json.Unmarshal(body, &entries); err != nil {
			t.Fatalf("decode entries: %v (body: %s)", err, body)
		}
		if len(entries) >= 2 || time.Now().After(deadline) {
			var out []int
			for _, e := range entries {
				out = append(out, e.Sgv)
			}
			return out
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestLANListenerServesReadingsOverTLS is the end-to-end proof a phone on the
// local network gets its readings over TLS: a client trusting only the test
// CA reads the exact synthetic entries over a LAN listener, both dialling its
// address and through a name the leaf certifies, while the loopback
// listener_addr keeps serving plain http. A handshake that returns no
// readings fails it.
func TestLANListenerServesReadingsOverTLS(t *testing.T) {
	t.Parallel()
	pki := newTestPKI(t)
	r := startLANRelay(t, pki, lanFake(t))
	path := "/api/v1/entries.json?count=10&token=" + lanTestToken
	want := []int{133, 121}

	direct := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pki.roots}}}
	if got := readSgvs(t, direct, "https://"+r.addrs.LAN[0]+path); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("sgv over TLS by address = %v, want %v", got, want)
	}

	// A declared name mapping: the dialer resolves lanTestName to the
	// listener, so the client verifies the leaf's DNS name rather than its IP.
	_, port, _ := net.SplitHostPort(r.addrs.LAN[0])
	mapped := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: pki.roots},
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if addr != net.JoinHostPort(lanTestName, port) {
				return nil, fmt.Errorf("unexpected dial to %s", addr)
			}
			return (&net.Dialer{}).DialContext(ctx, network, r.addrs.LAN[0])
		},
	}}
	if got := readSgvs(t, mapped, "https://"+net.JoinHostPort(lanTestName, port)+path); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("sgv over TLS by name = %v, want %v", got, want)
	}

	// The token check is the same one the loopback listener applies.
	resp, err := direct.Get("https://" + r.addrs.LAN[0] + "/api/v1/entries.json?count=10")
	if err != nil {
		t.Fatalf("GET without a token: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK || strings.Contains(string(body), "sgv") {
		t.Errorf("LAN listener served a request with no token: status %d, body %s", resp.StatusCode, body)
	}

	// listen_addr is still plain http.
	if got := readSgvs(t, http.DefaultClient, "http://"+r.addrs.Nightscout+path); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("sgv over plain http on listen_addr = %v, want %v", got, want)
	}
}

// TestLANListenerRefusesPlainHTTP proves a plain http request to a LAN
// listener gets no application data: a transport error, or Go's own fixed
// reply to http spoken to an https port and nothing else.
func TestLANListenerRefusesPlainHTTP(t *testing.T) {
	t.Parallel()
	pki := newTestPKI(t)
	r := startLANRelay(t, pki, lanFake(t))

	// Wait until the relay has data, so a plaintext listener would have
	// something to leak.
	direct := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pki.roots}}}
	path := "/api/v1/entries.json?count=10&token=" + lanTestToken
	if got := readSgvs(t, direct, "https://"+r.addrs.LAN[0]+path); len(got) == 0 {
		t.Fatal("no readings to protect")
	}

	resp, err := http.Get("http://" + r.addrs.LAN[0] + path)
	if err != nil {
		return
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	const goFixed = "Client sent an HTTP request to an HTTPS server.\n"
	if resp.StatusCode != http.StatusBadRequest || string(body) != goFixed {
		t.Errorf("plain http to the LAN listener answered %d %q, want a transport error or 400 %q", resp.StatusCode, body, goFixed)
	}
}

// TestLANListenerRequiresTLS12 proves the minimum protocol version: clients
// pinned to TLS 1.0 and 1.1 fail the handshake with a protocol version
// alert, while a TLS 1.2 client succeeds against the same listener.
func TestLANListenerRequiresTLS12(t *testing.T) {
	t.Parallel()
	pki := newTestPKI(t)
	r := startLANRelay(t, pki, lanFake(t))

	handshake := func(version uint16) error {
		conn, err := tls.Dial("tcp", r.addrs.LAN[0], &tls.Config{RootCAs: pki.roots, MinVersion: version, MaxVersion: version})
		if err != nil {
			return err
		}
		return conn.Close()
	}
	for _, c := range []struct {
		name    string
		version uint16
	}{{"TLS 1.0", tls.VersionTLS10}, {"TLS 1.1", tls.VersionTLS11}} {
		err := handshake(c.version)
		if err == nil {
			t.Errorf("%s client completed a handshake, want it refused", c.name)
		} else if !strings.Contains(err.Error(), "protocol version") {
			t.Errorf("%s client failed with %v, want a protocol version failure", c.name, err)
		}
	}
	if err := handshake(tls.VersionTLS12); err != nil {
		t.Errorf("TLS 1.2 control client failed: %v", err)
	}
}

// TestLANListenerRefusals proves every unusable LAN configuration is refused
// before anything binds, naming the field: through the stdin path, and for
// the certificate and key cases through relay.Run itself, which a caller
// building a Config directly reaches without the stdin checks. Every case
// then shows listen_addr, and for the Run cases the LAN address too, accept
// no connection.
func TestLANListenerRefusals(t *testing.T) {
	t.Parallel()
	good := newTestPKI(t)
	other := newTestPKI(t)
	garbage := "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
	garbageKey := "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"

	pemCases := []struct {
		name, cert, key, wantField string
	}{
		{"no certificate", "", good.keyPEM, "tls_cert_pem"},
		{"no key", good.certPEM, "", "tls_key_pem"},
		{"malformed certificate", garbage, good.keyPEM, "tls_cert_pem"},
		{"certificate that is not PEM", "not a certificate", good.keyPEM, "tls_cert_pem"},
		{"malformed key", good.certPEM, garbageKey, "tls_key_pem"},
		{"key that is not PEM", good.certPEM, "not a key", "tls_key_pem"},
		{"key of another certificate", good.certPEM, other.keyPEM, "does not match"},
	}
	addrCases := []struct{ name, addr string }{
		{"IPv6", "[fd00::1]:8443"},
		{"IPv4-mapped IPv6", "[::ffff:192.168.1.5]:8443"},
		{"wildcard", "0.0.0.0:8443"},
		{"empty host", ":8443"},
		{"loopback", "127.0.0.1:8443"},
		{"public", "8.8.8.8:8443"},
		{"just outside 172.16/12", "172.32.0.1:8443"},
		{"tailnet", "100.64.1.2:8443"},
		{"hostname", "mac.local:8443"},
		{"no port", "192.168.1.5"},
		{"port out of range", "192.168.1.5:70000"},
	}

	for _, c := range pemCases {
		t.Run("stdin/"+c.name, func(t *testing.T) {
			t.Parallel()
			listen := freeLoopbackAddr(t)
			var stdout, stderr bytes.Buffer
			serveStdin(context.Background(), lanStdin(t, map[string]any{
				"listen_addr":      listen,
				"lan_listen_addrs": []string{lanTestPrivate},
				"tls_cert_pem":     c.cert,
				"tls_key_pem":      c.key,
			}), &stdout, &stderr)
			if !strings.Contains(stderr.String(), c.wantField) {
				t.Errorf("stderr = %q, want it to name %q", stderr.String(), c.wantField)
			}
			if stdout.Len() != 0 {
				t.Errorf("stdout = %q, want nothing: the relay never became ready", stdout.String())
			}
			assertNothingListening(t, listen)
		})
		t.Run("run/"+c.name, func(t *testing.T) {
			t.Parallel()
			listen, lan := freeLoopbackAddr(t), freeLoopbackAddr(t)
			cfg, err := config.LoadFromReader(strings.NewReader(lanStdin(t, map[string]any{"listen_addr": listen})))
			if err != nil {
				t.Fatalf("LoadFromReader: %v", err)
			}
			cfg.LANListenAddrs, cfg.TLSCertPEM, cfg.TLSKeyPEM = []string{lan}, c.cert, c.key

			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			var stdout, stderr bytes.Buffer
			runLAN(ctx, cfg, &stdout, &stderr)
			if ctx.Err() != nil {
				t.Fatal("relay.Run kept serving a LAN listener it should have refused")
			}
			if !strings.Contains(stderr.String(), c.wantField) {
				t.Errorf("stderr = %q, want it to name %q", stderr.String(), c.wantField)
			}
			assertNothingListening(t, listen)
			assertNothingListening(t, lan)
		})
	}
	for _, c := range addrCases {
		t.Run("stdin/"+c.name, func(t *testing.T) {
			t.Parallel()
			listen := freeLoopbackAddr(t)
			var stdout, stderr bytes.Buffer
			serveStdin(context.Background(), lanStdin(t, map[string]any{
				"listen_addr":      listen,
				"lan_listen_addrs": []string{lanTestPrivate, c.addr},
				"tls_cert_pem":     good.certPEM,
				"tls_key_pem":      good.keyPEM,
			}), &stdout, &stderr)
			if !strings.Contains(stderr.String(), "lan_listen_addrs") {
				t.Errorf("stderr = %q, want it to name lan_listen_addrs", stderr.String())
			}
			if stdout.Len() != 0 {
				t.Errorf("stdout = %q, want nothing: the relay never became ready", stdout.String())
			}
			assertNothingListening(t, listen)
		})
	}
}

// TestLANListenerNeverPrintsTheKey plants a distinct private key in a good
// run and in every failing run, and checks that nothing either writes to
// stdout or stderr carries that key as PEM, DER or base64, whole or in part.
func TestLANListenerNeverPrintsTheKey(t *testing.T) {
	t.Parallel()
	goodRun := newTestPKI(t)
	r := startLANRelay(t, goodRun, lanFake(t))
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: goodRun.roots}}}
	readSgvs(t, client, "https://"+r.addrs.LAN[0]+"/api/v1/entries.json?count=10&token="+lanTestToken)
	_, _ = http.Get("http://" + r.addrs.LAN[0] + "/") // a failed handshake, logged or not
	r.stop()
	assertNoKeyMaterial(t, "good run stdout", r.stdout.String(), goodRun)
	assertNoKeyMaterial(t, "good run stderr", r.stderr.String(), goodRun)
	if r.stdout.String() != "ready\n" {
		t.Errorf("good run stdout = %q, want exactly the ready line", r.stdout.String())
	}

	cert := newTestPKI(t)
	mismatched := newTestPKI(t) // a second planted key, paired with the wrong certificate
	failing := map[string]map[string]any{
		"mismatched pair":    {"tls_cert_pem": cert.certPEM, "tls_key_pem": mismatched.keyPEM},
		"key as certificate": {"tls_cert_pem": cert.keyPEM, "tls_key_pem": cert.keyPEM},
		"truncated key":      {"tls_cert_pem": cert.certPEM, "tls_key_pem": cert.keyPEM[:len(cert.keyPEM)/2]},
		"bad address":        {"lan_listen_addrs": []string{"8.8.8.8:1"}, "tls_cert_pem": cert.certPEM, "tls_key_pem": cert.keyPEM},
		"no certificate":     {"tls_key_pem": cert.keyPEM},
	}
	for name, fields := range failing {
		t.Run(name, func(t *testing.T) {
			if _, ok := fields["lan_listen_addrs"]; !ok {
				fields["lan_listen_addrs"] = []string{lanTestPrivate}
			}
			var stdout, stderr bytes.Buffer
			serveStdin(context.Background(), lanStdin(t, fields), &stdout, &stderr)
			if stderr.Len() == 0 {
				t.Fatal("a failing run wrote nothing to stderr, want a refusal")
			}
			for _, k := range []testPKI{cert, mismatched} {
				assertNoKeyMaterial(t, "stdout", stdout.String(), k)
				assertNoKeyMaterial(t, "stderr", stderr.String(), k)
			}
		})
	}
}
