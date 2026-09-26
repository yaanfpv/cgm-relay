package config_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/yaanfpv/cgm-relay/internal/config"
)

// scriptedStdin returns a pipe whose read end behaves like a piped,
// non-terminal stdin fed exactly lines, and writes them (each newline
// terminated) before the caller reads. The write end is closed once the
// lines are written, so a short read past the last line sees EOF rather
// than blocking.
func scriptedStdin(t *testing.T, lines ...string) *os.File {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	t.Cleanup(func() { r.Close() })
	go func() {
		defer w.Close()
		for _, line := range lines {
			if _, err := w.WriteString(line + "\n"); err != nil {
				return
			}
		}
	}()
	return r
}

func TestSetupWritesConfigAndKeyWithSecurePermissions(t *testing.T) {
	withCleanEnv(t)
	paths, err := config.DefaultPaths()
	if err != nil {
		t.Fatalf("DefaultPaths: %v", err)
	}

	stdin := scriptedStdin(t, "person@example.test", "correct-horse-battery-staple")
	var stdout bytes.Buffer

	cfg, err := config.Setup(stdin, &stdout, false)
	if err != nil {
		t.Fatalf("Setup: %v", err)
	}

	if cfg.LibreLinkUpEmail != "person@example.test" {
		t.Errorf("LibreLinkUpEmail = %q, want %q", cfg.LibreLinkUpEmail, "person@example.test")
	}
	if cfg.LibreLinkUpPassword != "correct-horse-battery-staple" {
		t.Errorf("LibreLinkUpPassword = %q, want %q", cfg.LibreLinkUpPassword, "correct-horse-battery-staple")
	}
	if cfg.Token == "" {
		t.Error("Token is empty, want a generated token")
	}
	if len(cfg.Key) != 32 {
		t.Errorf("len(Key) = %d, want 32", len(cfg.Key))
	}

	// File mode: config file, key file, and both directories must be
	// exactly the modes below -- group- or world-readable is the one thing
	// this test exists to catch.
	for _, want := range []struct {
		path string
		perm os.FileMode
	}{
		{paths.ConfigFile, 0o600},
		{paths.KeyFile, 0o600},
		{paths.Dir, 0o700},
		{paths.DataDir, 0o700},
	} {
		info, err := os.Stat(want.path)
		if err != nil {
			t.Fatalf("Stat %s: %v", want.path, err)
		}
		if got := info.Mode().Perm(); got != want.perm {
			t.Errorf("mode of %s = %o, want %o", want.path, got, want.perm)
		}
	}

	// The config file must carry the token and email, but never the
	// key: the key lives only in its own file.
	data, err := os.ReadFile(paths.ConfigFile)
	if err != nil {
		t.Fatalf("read config file: %v", err)
	}
	var onDisk map[string]any
	if err := json.Unmarshal(data, &onDisk); err != nil {
		t.Fatalf("unmarshal config file: %v", err)
	}
	if onDisk["token"] != cfg.Token {
		t.Errorf("config file token = %v, want %q", onDisk["token"], cfg.Token)
	}
	if _, present := onDisk["Key"]; present {
		t.Error("config file has a Key field, want the key excluded entirely")
	}
	if _, present := onDisk["key"]; present {
		t.Error("config file has a key field, want the key excluded entirely")
	}

	keyData, err := os.ReadFile(paths.KeyFile)
	if err != nil {
		t.Fatalf("read key file: %v", err)
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(keyData)))
	if err != nil {
		t.Fatalf("decode key file: %v", err)
	}
	if !bytes.Equal(decoded, cfg.Key) {
		t.Error("key file does not decode to the returned Key")
	}

	if got := strings.Count(stdout.String(), cfg.Token); got != 1 {
		t.Errorf("token appears %d times in stdout, want exactly 1", got)
	}
	if !strings.Contains(stdout.String(), "paste") {
		t.Error("stdout has no line telling the user where to paste the token")
	}
}

func TestSetupRefusesToOverwriteWithoutForce(t *testing.T) {
	withCleanEnv(t)
	paths, err := config.DefaultPaths()
	if err != nil {
		t.Fatalf("DefaultPaths: %v", err)
	}

	first := scriptedStdin(t, "first@example.test", "first-password")
	if _, err := config.Setup(first, &bytes.Buffer{}, false); err != nil {
		t.Fatalf("first Setup: %v", err)
	}
	keyAfterFirst, err := os.ReadFile(paths.KeyFile)
	if err != nil {
		t.Fatalf("read key file after first Setup: %v", err)
	}

	second := scriptedStdin(t, "second@example.test", "second-password")
	_, err = config.Setup(second, &bytes.Buffer{}, false)
	if err == nil {
		t.Fatal("second Setup without --force succeeded, want a refusal")
	}
	if !strings.Contains(err.Error(), "already exists") {
		t.Errorf("error = %v, want it to say the config already exists", err)
	}

	data, err := os.ReadFile(paths.ConfigFile)
	if err != nil {
		t.Fatalf("read config file: %v", err)
	}
	if !strings.Contains(string(data), "first@example.test") {
		t.Error("config file was changed by the refused second Setup call")
	}

	third := scriptedStdin(t, "third@example.test", "third-password")
	cfg, err := config.Setup(third, &bytes.Buffer{}, true)
	if err != nil {
		t.Fatalf("third Setup with --force: %v", err)
	}
	if cfg.LibreLinkUpEmail != "third@example.test" {
		t.Errorf("--force Setup email = %q, want %q", cfg.LibreLinkUpEmail, "third@example.test")
	}

	// --force replaces the credentials and token, but the key file --
	// and therefore every reading already sealed with it -- must survive
	// byte-for-byte: a rotated key would make the existing store
	// permanently unreadable.
	keyAfterForce, err := os.ReadFile(paths.KeyFile)
	if err != nil {
		t.Fatalf("read key file after --force Setup: %v", err)
	}
	if !bytes.Equal(keyAfterFirst, keyAfterForce) {
		t.Error("--force Setup rotated the encryption key, want it kept byte-identical")
	}
	if !bytes.Equal(cfg.Key, keyAfterFirstDecoded(t, keyAfterFirst)) {
		t.Error("--force Setup returned a Key that does not match the surviving key file")
	}
}

// keyAfterFirstDecoded decodes a key file's base64 contents, for
// comparing against a Config.Key a later Setup call returned.
func keyAfterFirstDecoded(t *testing.T, keyFileContents []byte) []byte {
	t.Helper()
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(keyFileContents)))
	if err != nil {
		t.Fatalf("decode key file: %v", err)
	}
	return decoded
}

// TestSetupReusesExistingKeyFileWithoutOverwritingIt checks that Setup
// never replaces the encryption key of an existing reading store: a key
// file already at the default path -- even with no config file beside
// it, as an environment-only or partially completed prior install would
// leave -- is kept exactly as is, never regenerated, and Setup says so
// without printing the key.
func TestSetupReusesExistingKeyFileWithoutOverwritingIt(t *testing.T) {
	withCleanEnv(t)
	paths, err := config.DefaultPaths()
	if err != nil {
		t.Fatalf("DefaultPaths: %v", err)
	}

	if err := os.MkdirAll(paths.Dir, 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", paths.Dir, err)
	}
	preexisting := testKeyBase64('P') + "\n"
	if err := os.WriteFile(paths.KeyFile, []byte(preexisting), 0o600); err != nil {
		t.Fatalf("write pre-existing key file: %v", err)
	}

	stdin := scriptedStdin(t, "person@example.test", "some-password")
	var stdout bytes.Buffer
	cfg, err := config.Setup(stdin, &stdout, false)
	if err != nil {
		t.Fatalf("Setup: %v", err)
	}

	if !bytes.Equal(cfg.Key, testKeyBytes('P')) {
		t.Error("Setup generated a new key instead of reusing the pre-existing one")
	}

	after, err := os.ReadFile(paths.KeyFile)
	if err != nil {
		t.Fatalf("read key file after Setup: %v", err)
	}
	if string(after) != preexisting {
		t.Error("Setup rewrote the pre-existing key file's bytes")
	}

	if !strings.Contains(stdout.String(), "existing") {
		t.Error("stdout does not say the existing key was kept")
	}
	if strings.Contains(stdout.String(), testKeyBase64('P')) {
		t.Error("stdout contains the reused key's own value")
	}
}

func TestSetupRejectsEmptyEmailOrPassword(t *testing.T) {
	cases := []struct {
		name  string
		lines []string
	}{
		{"empty email", []string{"", "some-password"}},
		{"empty password", []string{"person@example.test", ""}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withCleanEnv(t)
			stdin := scriptedStdin(t, c.lines...)
			_, err := config.Setup(stdin, &bytes.Buffer{}, false)
			if err == nil {
				t.Fatal("Setup accepted an empty credential, want an error")
			}
		})
	}
}

// TestSetupOutputNeverLeaksSecrets checks that every byte Setup writes to
// stdout, and every error message it can return, never carries the
// entered password or the email -- neither may appear anywhere except the
// deliberate token line, which carries no secret other than the token
// itself.
func TestSetupOutputNeverLeaksSecrets(t *testing.T) {
	withCleanEnv(t)
	const email = "leak-check@example.test"
	const password = "s3cr3t-p4ssw0rd-should-never-print"

	stdin := scriptedStdin(t, email, password)
	var stdout bytes.Buffer
	cfg, err := config.Setup(stdin, &stdout, false)
	if err != nil {
		t.Fatalf("Setup: %v", err)
	}

	if strings.Contains(stdout.String(), password) {
		t.Error("stdout contains the LibreLinkUp password")
	}
	if strings.Contains(stdout.String(), email) {
		t.Error("stdout contains the LibreLinkUp email")
	}
	if strings.Contains(stdout.String(), base64.StdEncoding.EncodeToString(cfg.Key)) {
		t.Error("stdout contains the encryption key")
	}

	// A refused second Setup call is the one error path this function
	// can reach with real secrets already generated; it must not echo
	// any of them either.
	second := scriptedStdin(t, "someone-else@example.test", "another-password")
	_, err = config.Setup(second, &bytes.Buffer{}, false)
	if err == nil {
		t.Fatal("second Setup without --force succeeded, want a refusal")
	}
	if strings.Contains(err.Error(), password) || strings.Contains(err.Error(), email) {
		t.Errorf("refusal error leaks a secret: %v", err)
	}
}
