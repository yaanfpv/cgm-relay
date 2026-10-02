package relay_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
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

// factoryTimestampLayout matches librelinkup's own parseFactoryTimestamp
// layout ("2/13/2020 5:29:23 PM"-shaped), so this file's synthetic
// readings decode the same way a real LibreLinkUp response would.
const factoryTimestampLayout = "1/2/2006 3:04:05 PM"

// recentReadingTime returns a reading time close to the real wall clock,
// truncated to the second. Run's poller uses the real clock, and prunes
// on its very first cycle (poller.Run starts lastPrune a full
// PruneInterval in the past specifically so that first prune happens
// immediately) -- a fixed, long-past timestamp would fall outside the
// configured retention and be deleted before any test could observe it.
func recentReadingTime() time.Time {
	return time.Now().UTC().Truncate(time.Second)
}

// testConfig returns a Config with every required field filled in with
// synthetic, recognizable values (never anything resembling a real
// account), an ephemeral port for both listeners, and a database
// directory that does not exist yet, so Run has to create it.
func testConfig(t *testing.T) config.Config {
	t.Helper()
	return config.Config{
		LibreLinkUpEmail:    "person@example.test",
		LibreLinkUpPassword: "leak-check-password-should-never-log",
		Token:               "leak-check-token-should-never-log",
		ListenAddr:          "127.0.0.1:0",
		StatusAddr:          "127.0.0.1:0",
		DatabasePath:        filepath.Join(t.TempDir(), "data", "readings.db"),
		RetentionDays:       15,
		Key:                 bytes.Repeat([]byte{'K'}, 32),
	}
}

// runRelay starts relay.Run in the background with cfg and opts, and
// returns the addresses it bound plus a function that cancels its
// context and waits (bounded) for Run to return, failing the test if it
// takes too long or returns an unexpected error.
func runRelay(t *testing.T, cfg config.Config, opts ...relay.Option) (relay.Addresses, func() error) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())

	ready := make(chan relay.Addresses, 1)
	allOpts := append([]relay.Option{relay.WithReady(func(a relay.Addresses) { ready <- a })}, opts...)

	runErr := make(chan error, 1)
	go func() { runErr <- relay.Run(ctx, cfg, allOpts...) }()

	var addrs relay.Addresses
	select {
	case addrs = <-ready:
	case err := <-runErr:
		cancel()
		t.Fatalf("relay.Run returned before becoming ready: %v", err)
	case <-time.After(5 * time.Second):
		cancel()
		t.Fatal("relay.Run did not become ready within 5s")
	}

	stop := func() error {
		start := time.Now()
		cancel()
		select {
		case err := <-runErr:
			if time.Since(start) > 5*time.Second {
				t.Errorf("relay.Run took %s to stop after cancellation, want a few seconds at most", time.Since(start))
			}
			return err
		case <-time.After(5 * time.Second):
			t.Fatal("relay.Run did not return within 5s of cancellation")
			return nil
		}
	}
	return addrs, stop
}

// TestRunServesAnEntryOverHTTP runs the relay in-process against llufake
// and reads an entry back over real HTTP with the token.
func TestRunServesAnEntryOverHTTP(t *testing.T) {
	t.Parallel()
	fake := llufake.New(t)
	readingTime := recentReadingTime()
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: readingTime.Format(factoryTimestampLayout),
		ValueInMgPerDl:   145,
		TrendArrow:       3,
	}, nil)
	source := librelinkup.New("person@example.test", "leak-check-password-should-never-log", librelinkup.WithBaseURL(fake.URL))

	cfg := testConfig(t)
	addrs, stop := runRelay(t, cfg, relay.WithSource(source))

	// The database directory did not exist before Run started; it must
	// now exist at mode 0700 regardless of the process umask.
	info, err := os.Stat(filepath.Dir(cfg.DatabasePath))
	if err != nil {
		t.Fatalf("stat database directory: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o700 {
		t.Errorf("database directory mode = %o, want %o", perm, 0o700)
	}

	url := fmt.Sprintf("http://%s/api/v1/entries/current.json?token=%s", addrs.Nightscout, cfg.Token)
	var entries []map[string]any
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err != nil {
			t.Fatalf("GET %s: %v", url, err)
		}
		body := mustReadAndClose(t, resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: status = %d, body = %s", url, resp.StatusCode, body)
		}
		if err := json.Unmarshal(body, &entries); err != nil {
			t.Fatalf("decode entries: %v (body: %s)", err, body)
		}
		if len(entries) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(entries) == 0 {
		t.Fatal("no entry was served within 5s of Run becoming ready")
	}
	if got := int(entries[0]["sgv"].(float64)); got != 145 {
		t.Errorf("sgv = %d, want 145", got)
	}

	// A request with no token must never be served.
	unauthResp, err := http.Get(fmt.Sprintf("http://%s/api/v1/entries/current.json", addrs.Nightscout))
	if err != nil {
		t.Fatalf("GET with no token: %v", err)
	}
	unauthResp.Body.Close()
	if unauthResp.StatusCode != http.StatusUnauthorized {
		t.Errorf("GET with no token: status = %d, want 401", unauthResp.StatusCode)
	}

	if err := stop(); err != nil && !errors.Is(err, context.Canceled) {
		t.Errorf("Run returned %v, want context.Canceled", err)
	}

	// The store must be closed by the time Run returns, so it can be
	// reopened immediately.
	st, err := store.Open(context.Background(), cfg.DatabasePath, cfg.Key)
	if err != nil {
		t.Fatalf("reopen store after Run stopped: %v", err)
	}
	st.Close()
}

// TestRunFromStdinConfig decodes a config the way `cgm-relay serve
// --config-stdin` does, via config.LoadFromReader on a JSON object piped
// in exactly as the menu bar app will send it, then runs the relay
// against llufake and reads an entry back over real HTTP with the
// resulting token. A dropped token, key or address shows up here as a
// refused request or a relay that never serves; llufake accepts any
// credentials, so the email and password mapping is TestLoadFromReader's
// to prove.
func TestRunFromStdinConfig(t *testing.T) {
	t.Parallel()
	fake := llufake.New(t)
	readingTime := recentReadingTime()
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: readingTime.Format(factoryTimestampLayout),
		ValueInMgPerDl:   150,
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

	cfg, err := config.LoadFromReader(strings.NewReader(stdinJSON))
	if err != nil {
		t.Fatalf("LoadFromReader: %v", err)
	}

	source := librelinkup.New(cfg.LibreLinkUpEmail, cfg.LibreLinkUpPassword, librelinkup.WithBaseURL(fake.URL))
	addrs, stop := runRelay(t, cfg, relay.WithSource(source))
	defer stop()

	url := fmt.Sprintf("http://%s/api/v1/entries/current.json?token=%s", addrs.Nightscout, cfg.Token)
	var entries []map[string]any
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err != nil {
			t.Fatalf("GET %s: %v", url, err)
		}
		body := mustReadAndClose(t, resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: status = %d, body = %s", url, resp.StatusCode, body)
		}
		if err := json.Unmarshal(body, &entries); err != nil {
			t.Fatalf("decode entries: %v (body: %s)", err, body)
		}
		if len(entries) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(entries) == 0 {
		t.Fatal("no entry was served within 5s of Run becoming ready")
	}
	if got := int(entries[0]["sgv"].(float64)); got != 150 {
		t.Errorf("sgv = %d, want 150", got)
	}
}

// TestRunUsesConfiguredLibreLinkUpBaseURL checks Run's own production
// wiring: with no relay.WithSource override at all, Run itself builds
// its LibreLinkUp source from cfg.LibreLinkUpBaseURL and reads an entry
// back over real HTTP, proving the engine actually talks to the fake
// rather than the official service.
func TestRunUsesConfiguredLibreLinkUpBaseURL(t *testing.T) {
	t.Parallel()
	fake := llufake.New(t)
	readingTime := recentReadingTime()
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: readingTime.Format(factoryTimestampLayout),
		ValueInMgPerDl:   142,
		TrendArrow:       3,
	}, nil)

	cfg := testConfig(t)
	cfg.LibreLinkUpBaseURL = fake.URL
	addrs, stop := runRelay(t, cfg)
	defer stop()

	url := fmt.Sprintf("http://%s/api/v1/entries/current.json?token=%s", addrs.Nightscout, cfg.Token)
	var entries []map[string]any
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err != nil {
			t.Fatalf("GET %s: %v", url, err)
		}
		body := mustReadAndClose(t, resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: status = %d, body = %s", url, resp.StatusCode, body)
		}
		if err := json.Unmarshal(body, &entries); err != nil {
			t.Fatalf("decode entries: %v (body: %s)", err, body)
		}
		if len(entries) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(entries) == 0 {
		t.Fatal("no entry was served within 5s of Run becoming ready")
	}
	if got := int(entries[0]["sgv"].(float64)); got != 142 {
		t.Errorf("sgv = %d, want 142", got)
	}

	reqs := fake.Requests()
	if len(reqs) == 0 {
		t.Fatal("the fake received no requests; Run did not use cfg.LibreLinkUpBaseURL to build its source")
	}
	if reqs[0].Path != "/llu/auth/login" {
		t.Errorf("first request path = %q, want /llu/auth/login", reqs[0].Path)
	}
}

// TestRunStatusEndpointTracksAuthenticatedClients drives llufake and two
// API clients with different User-Agents, then reads /status to check it
// reports the latest reading and tracks only the authenticated clients.
func TestRunStatusEndpointTracksAuthenticatedClients(t *testing.T) {
	t.Parallel()
	fake := llufake.New(t)
	readingTime := recentReadingTime()
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: readingTime.Format(factoryTimestampLayout),
		ValueInMgPerDl:   160,
		TrendArrow:       3,
	}, nil)
	source := librelinkup.New("person@example.test", "leak-check-password-should-never-log", librelinkup.WithBaseURL(fake.URL))

	cfg := testConfig(t)
	addrs, stop := runRelay(t, cfg, relay.WithSource(source))
	defer stop()

	entriesURL := fmt.Sprintf("http://%s/api/v1/entries/current.json?token=%s", addrs.Nightscout, cfg.Token)

	// Poll as two distinct follower clients until the reading is actually
	// there, so their recorded poll times are meaningful.
	waitForEntry(t, entriesURL, "xDrip4iOS/1.0")
	getWithUserAgent(t, entriesURL, "LoopFollow/1.0")

	// An unauthenticated request must never be counted as a client.
	unauthURL := fmt.Sprintf("http://%s/api/v1/entries/current.json", addrs.Nightscout)
	getWithUserAgent(t, unauthURL, "Nightguard/1.0")

	statusURL := fmt.Sprintf("http://%s/status", addrs.Status)
	resp, err := http.Get(statusURL)
	if err != nil {
		t.Fatalf("GET %s: %v", statusURL, err)
	}
	body := mustReadAndClose(t, resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: status = %d, body = %s", statusURL, resp.StatusCode, body)
	}

	var status struct {
		Running         bool                 `json:"running"`
		LastReadingMgDl int                  `json:"last_reading_mg_dl"`
		Clients         map[string]time.Time `json:"clients"`
	}
	if err := json.Unmarshal(body, &status); err != nil {
		t.Fatalf("decode /status: %v (body: %s)", err, body)
	}
	if !status.Running {
		t.Error("running = false, want true")
	}
	if status.LastReadingMgDl != 160 {
		t.Errorf("last_reading_mg_dl = %d, want 160", status.LastReadingMgDl)
	}
	if _, ok := status.Clients["xDrip4iOS/1.0"]; !ok {
		t.Errorf("clients does not carry xDrip4iOS/1.0, got %v", status.Clients)
	}
	if _, ok := status.Clients["LoopFollow/1.0"]; !ok {
		t.Errorf("clients does not carry LoopFollow/1.0, got %v", status.Clients)
	}
	if _, ok := status.Clients["Nightguard/1.0"]; ok {
		t.Error("an unauthenticated request was counted as a client")
	}
	if got := len(status.Clients); got != 2 {
		t.Errorf("len(clients) = %d, want 2, got %v", got, status.Clients)
	}

	if strings.Contains(string(body), cfg.Token) || strings.Contains(string(body), cfg.LibreLinkUpPassword) || strings.Contains(string(body), string(cfg.Key)) {
		t.Error("/status body carries a secret")
	}
}

// waitForEntry polls url as userAgent until it returns at least one
// entry, bounded to 5s, so a test can be sure the client it is about to
// check for in /status actually made an authenticated request that
// succeeded.
func waitForEntry(t *testing.T, url, userAgent string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var entries []map[string]any
		body := getWithUserAgent(t, url, userAgent)
		if err := json.Unmarshal(body, &entries); err == nil && len(entries) > 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no entry served to %s within 5s", userAgent)
}

// getWithUserAgent issues a GET to url with the given User-Agent header
// and returns the response body, failing the test on a request error.
func getWithUserAgent(t *testing.T, url, userAgent string) []byte {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("build request for %s: %v", url, err)
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	return mustReadAndClose(t, resp.Body)
}

// TestRunStatusEndpointRefusesSpoofedHost checks, driven over real HTTP
// against the actual listener, that a request spoofing a non-loopback
// Host (what a page retargeting its own domain to 127.0.0.1 would send)
// is refused with 403 and no reading data, while the ordinary case -- a
// client that simply dials the loopback address, as Go's own http.Client
// does -- is still answered normally.
func TestRunStatusEndpointRefusesSpoofedHost(t *testing.T) {
	t.Parallel()
	fake := llufake.New(t)
	readingTime := recentReadingTime()
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: readingTime.Format(factoryTimestampLayout),
		ValueInMgPerDl:   177,
		TrendArrow:       3,
	}, nil)
	source := librelinkup.New("person@example.test", "some-password", librelinkup.WithBaseURL(fake.URL))

	cfg := testConfig(t)
	addrs, stop := runRelay(t, cfg, relay.WithSource(source))
	defer stop()

	statusURL := fmt.Sprintf("http://%s/status", addrs.Status)

	for _, spoofedHost := range []string{"evil.example", "evil.example:1338", "192.168.1.5:1338"} {
		t.Run(spoofedHost, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, statusURL, nil)
			if err != nil {
				t.Fatalf("build request: %v", err)
			}
			req.Host = spoofedHost
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("GET %s with Host %q: %v", statusURL, spoofedHost, err)
			}
			body := mustReadAndClose(t, resp.Body)
			if resp.StatusCode != http.StatusForbidden {
				t.Errorf("Host %q: status = %d, want 403 (body: %s)", spoofedHost, resp.StatusCode, body)
			}
			if relay.ContainsValue(string(body), "177") {
				t.Errorf("Host %q: refused response body carries the reading value: %s", spoofedHost, body)
			}
		})
	}

	// The ordinary case (dialling the loopback address directly, no Host
	// spoofing) must still work.
	resp, err := http.Get(statusURL)
	if err != nil {
		t.Fatalf("GET %s: %v", statusURL, err)
	}
	body := mustReadAndClose(t, resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("ordinary GET %s: status = %d, want 200 (body: %s)", statusURL, resp.StatusCode, body)
	}
}

// TestRunBindsExactlyConfiguredAddress checks that Run binds exactly the
// host the configuration names, never widening a loopback address to a
// wildcard, and never narrowing an explicitly wide one to loopback
// either. It checks this with config.IsLoopbackAddr rather than a literal
// host string, since the exact string a listener reports for an
// unspecified bind ("0.0.0.0" vs "::" vs "[::]") is a platform detail of
// the network stack, not something Run controls.
func TestRunBindsExactlyConfiguredAddress(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name         string
		addr         string
		wantLoopback bool
	}{
		{name: "loopback", addr: "127.0.0.1:0", wantLoopback: true},
		{name: "explicitly wide", addr: "0.0.0.0:0", wantLoopback: false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			fake := llufake.New(t)
			source := librelinkup.New("person@example.test", "some-password", librelinkup.WithBaseURL(fake.URL))

			cfg := testConfig(t)
			cfg.ListenAddr = c.addr
			addrs, stop := runRelay(t, cfg, relay.WithSource(source))
			defer stop()

			if got := config.IsLoopbackAddr(addrs.Nightscout); got != c.wantLoopback {
				t.Errorf("IsLoopbackAddr(%q) = %v, want %v", addrs.Nightscout, got, c.wantLoopback)
			}
		})
	}
}

// syncBuffer is a bytes.Buffer safe for one goroutine to write to (via
// log.Logger, which serializes its own Printf calls) while another
// reads it, which a bare bytes.Buffer is not: log.Logger only
// synchronizes its own writes against each other, never against a
// concurrent read of the buffer it is writing into.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

func (s *syncBuffer) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Len()
}

// TestRunLogsNoSecrets checks that neither a failing sign-in nor a normal
// run ever writes the account password, the Nightscout token, or the
// store key to the log.
func TestRunLogsNoSecrets(t *testing.T) {
	t.Parallel()
	t.Run("failing sign-in", func(t *testing.T) {
		t.Parallel()
		fake := llufake.New(t)
		fake.RejectCredentials()
		source := librelinkup.New("person@example.test", "leak-check-password-should-never-log", librelinkup.WithBaseURL(fake.URL))

		logs := &syncBuffer{}
		cfg := testConfig(t)
		_, stop := runRelay(t, cfg, relay.WithSource(source), relay.WithLogOutput(logs))

		// The poller's first fetch fails almost immediately; wait for the
		// status watcher to have logged something before checking it,
		// so this test cannot pass vacuously on an empty log.
		waitForCondition(t, func() bool { return strings.Contains(logs.String(), "poller:") })

		stop()
		assertNoSecrets(t, logs.String(), cfg)
	})

	t.Run("normal run", func(t *testing.T) {
		t.Parallel()
		fake := llufake.New(t)
		readingTime := recentReadingTime()
		fake.SetGraph(&llufake.Measurement{
			FactoryTimestamp: readingTime.Format(factoryTimestampLayout),
			ValueInMgPerDl:   111,
			TrendArrow:       3,
		}, nil)
		source := librelinkup.New("person@example.test", "leak-check-password-should-never-log", librelinkup.WithBaseURL(fake.URL))

		logs := &syncBuffer{}
		cfg := testConfig(t)
		_, stop := runRelay(t, cfg, relay.WithSource(source), relay.WithLogOutput(logs))
		stop()

		if logs.Len() == 0 {
			t.Fatal("no log output at all; the startup lines should always be written")
		}
		assertNoSecrets(t, logs.String(), cfg)
		if relay.ContainsValue(logs.String(), "111") {
			t.Error("log output carries the synthetic glucose value")
		}
	})
}

// assertNoSecrets fails the test if output contains cfg's password,
// token, or encryption key.
func assertNoSecrets(t *testing.T, output string, cfg config.Config) {
	t.Helper()
	if strings.Contains(output, cfg.LibreLinkUpPassword) {
		t.Error("log output carries the LibreLinkUp password")
	}
	if strings.Contains(output, cfg.Token) {
		t.Error("log output carries the Nightscout token")
	}
	if strings.Contains(output, string(cfg.Key)) {
		t.Error("log output carries the store encryption key")
	}
}

// waitForCondition polls cond every millisecond for up to 5s, failing the
// test if it never becomes true.
func waitForCondition(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition never became true within 5s")
}

// mustReadAndClose reads body fully and closes it, failing the test on a
// read error.
func mustReadAndClose(t *testing.T, body io.ReadCloser) []byte {
	t.Helper()
	defer body.Close()
	data, err := io.ReadAll(body)
	if err != nil {
		t.Fatalf("read response body: %v", err)
	}
	return data
}

// TestRunPairingPageIsReachableButItsMintRouteIsNot drives the real
// listeners: a code is minted over the loopback status endpoint (and only
// there), the phone-facing listener serves the pairing page for it without
// a credential, and that listener has no route that mints a code, so a
// phone or tailnet peer cannot make one.
func TestRunPairingPageIsReachableButItsMintRouteIsNot(t *testing.T) {
	t.Parallel()
	fake := llufake.New(t)
	source := librelinkup.New("person@example.test", "some-password", librelinkup.WithBaseURL(fake.URL))
	cfg := testConfig(t)
	addrs, stop := runRelay(t, cfg, relay.WithSource(source))
	defer stop()

	mintBody := `{"apps":[{"name":"A","steps":["s"],"fields":[{"label":"Token","value":"{token}"}],"links":[]}]}`
	post := func(url, host string) (int, []byte) {
		req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(mintBody))
		if err != nil {
			t.Fatalf("build request: %v", err)
		}
		req.Header.Set("Content-Type", "application/json")
		if host != "" {
			req.Host = host
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("POST %s: %v", url, err)
		}
		return resp.StatusCode, mustReadAndClose(t, resp.Body)
	}

	if status, _ := post(fmt.Sprintf("http://%s/pairing", addrs.Nightscout), ""); status == http.StatusOK {
		t.Fatal("the phone-facing listener minted a code")
	}
	if status, body := post(fmt.Sprintf("http://%s/pairing", addrs.Status), "relay.example.test"); status != http.StatusForbidden {
		t.Fatalf("mint with a spoofed Host: status = %d, want 403 (body %s)", status, body)
	}

	status, body := post(fmt.Sprintf("http://%s/pairing", addrs.Status), "")
	if status != http.StatusOK {
		t.Fatalf("mint over loopback: status = %d, body %s", status, body)
	}
	var minted struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(body, &minted); err != nil || minted.Code == "" {
		t.Fatalf("decode mint response %s: %v", body, err)
	}

	pageURL := fmt.Sprintf("http://%s/connect/%s", addrs.Nightscout, minted.Code)
	resp, err := http.Get(pageURL)
	if err != nil {
		t.Fatalf("GET %s: %v", pageURL, err)
	}
	page := mustReadAndClose(t, resp.Body)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(page), cfg.Token) {
		t.Fatalf("pairing page: status = %d, token shown = %v", resp.StatusCode, strings.Contains(string(page), cfg.Token))
	}
	if strings.Contains(pageURL, cfg.Token) {
		t.Error("the pairing URL carries the token")
	}
}
