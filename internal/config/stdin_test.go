package config_test

import (
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/config"
)

// TestLoadFromReader checks that a full stdin JSON object decodes to
// exactly the fields it names, with the same defaults Load applies for
// anything it leaves out, and that key_path is ignored even when it is
// present and names a real, different key.
func TestLoadFromReader(t *testing.T) {
	t.Run("full config, defaults applied where absent", func(t *testing.T) {
		input := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "database_path": "/tmp/does-not-matter/readings.db",
  "key_path": "/tmp/does-not-exist/key",
  "retention_days": 30,
  "key": %q
}`, testKeyBase64('K'))

		got, err := config.LoadFromReader(strings.NewReader(input))
		if err != nil {
			t.Fatalf("LoadFromReader: %v", err)
		}
		want := config.Config{
			LibreLinkUpEmail:    "person@example.test",
			LibreLinkUpPassword: "some-password",
			Token:               "some-token",
			ListenAddr:          config.DefaultListenAddr,
			StatusAddr:          config.DefaultStatusAddr,
			DatabasePath:        "/tmp/does-not-matter/readings.db",
			KeyPath:             "",
			RetentionDays:       30,
			Key:                 testKeyBytes('K'),
		}
		assertConfigEqual(t, got, want)
	})

	t.Run("every field explicit, nothing defaulted", func(t *testing.T) {
		input := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "listen_addr": "127.0.0.1:6001",
  "status_addr": "127.0.0.1:6002",
  "database_path": "/tmp/stdin-readings.db",
  "retention_days": 7,
  "key": %q
}`, testKeyBase64('S'))

		got, err := config.LoadFromReader(strings.NewReader(input))
		if err != nil {
			t.Fatalf("LoadFromReader: %v", err)
		}
		want := config.Config{
			LibreLinkUpEmail:    "person@example.test",
			LibreLinkUpPassword: "some-password",
			Token:               "some-token",
			ListenAddr:          "127.0.0.1:6001",
			StatusAddr:          "127.0.0.1:6002",
			DatabasePath:        "/tmp/stdin-readings.db",
			KeyPath:             "",
			RetentionDays:       7,
			Key:                 testKeyBytes('S'),
		}
		assertConfigEqual(t, got, want)
	})

	t.Run("status_secret is optional and carried through when present", func(t *testing.T) {
		const secret = "per-launch-secret-0123456789abcdef"
		withSecret := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "status_secret": %q,
  "key": %q
}`, secret, testKeyBase64('K'))
		got, err := config.LoadFromReader(strings.NewReader(withSecret))
		if err != nil {
			t.Fatalf("LoadFromReader: %v", err)
		}
		if got.StatusSecret != secret {
			t.Errorf("StatusSecret = %q, want %q", got.StatusSecret, secret)
		}

		without := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "key": %q
}`, testKeyBase64('K'))
		got, err = config.LoadFromReader(strings.NewReader(without))
		if err != nil {
			t.Fatalf("LoadFromReader: %v", err)
		}
		if got.StatusSecret != "" {
			t.Errorf("StatusSecret = %q, want empty when stdin names none", got.StatusSecret)
		}
	})

	t.Run("librelinkup_base_url is optional, absent means the official service", func(t *testing.T) {
		input := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "key": %q
}`, testKeyBase64('K'))

		got, err := config.LoadFromReader(strings.NewReader(input))
		if err != nil {
			t.Fatalf("LoadFromReader: %v", err)
		}
		if got.LibreLinkUpBaseURL != "" {
			t.Errorf("LibreLinkUpBaseURL = %q, want empty", got.LibreLinkUpBaseURL)
		}
	})

	t.Run("librelinkup_base_url points the engine at a fake", func(t *testing.T) {
		input := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "librelinkup_base_url": "http://127.0.0.1:9999",
  "key": %q
}`, testKeyBase64('K'))

		got, err := config.LoadFromReader(strings.NewReader(input))
		if err != nil {
			t.Fatalf("LoadFromReader: %v", err)
		}
		if got.LibreLinkUpBaseURL != "http://127.0.0.1:9999" {
			t.Errorf("LibreLinkUpBaseURL = %q, want %q", got.LibreLinkUpBaseURL, "http://127.0.0.1:9999")
		}
	})

	t.Run("key_path is ignored even when it names a real file with a different key", func(t *testing.T) {
		keyFile := filepath.Join(t.TempDir(), "key")
		if err := os.WriteFile(keyFile, []byte(testKeyBase64('D')+"\n"), 0o600); err != nil {
			t.Fatalf("write decoy key file: %v", err)
		}

		input := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "key_path": %q,
  "retention_days": 30,
  "key": %q
}`, keyFile, testKeyBase64('K'))

		got, err := config.LoadFromReader(strings.NewReader(input))
		if err != nil {
			t.Fatalf("LoadFromReader: %v", err)
		}
		if string(got.Key) != string(testKeyBytes('K')) {
			t.Error("LoadFromReader used the key_path file's key instead of the \"key\" field")
		}
		if got.KeyPath != "" {
			t.Errorf("KeyPath = %q, want it cleared", got.KeyPath)
		}
	})

	t.Run("database_path absent defaults to the per-user data file, as Load does", func(t *testing.T) {
		withCleanEnv(t)
		paths, err := config.DefaultPaths()
		if err != nil {
			t.Fatalf("DefaultPaths: %v", err)
		}

		input := fmt.Sprintf(`{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "key": %q
}`, testKeyBase64('K'))

		got, err := config.LoadFromReader(strings.NewReader(input))
		if err != nil {
			t.Fatalf("LoadFromReader: %v", err)
		}
		if got.DatabasePath != paths.DatabaseFile {
			t.Errorf("DatabasePath = %q, want %q (an empty path is SQLite's temporary database, lost on every restart)", got.DatabasePath, paths.DatabaseFile)
		}
	})

	t.Run("decodes as soon as it has one object, without waiting for the reader to reach EOF", func(t *testing.T) {
		r, w := io.Pipe()
		t.Cleanup(func() { w.Close() })

		input := fmt.Sprintf(`{"librelinkup_email": "person@example.test", "librelinkup_password": "some-password", "token": "some-token", "key": %q}`, testKeyBase64('K'))

		done := make(chan error, 1)
		go func() {
			_, err := config.LoadFromReader(r)
			done <- err
		}()

		if _, err := w.Write([]byte(input)); err != nil {
			t.Fatalf("write to pipe: %v", err)
		}

		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("LoadFromReader: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("LoadFromReader waited for EOF instead of returning once it had decoded one object; the pipe was never closed")
		}
	})
}

// TestLoadFromReaderIgnoresFileAndEnvironment checks that, with a
// conflicting config file and every CGM_RELAY_* variable set to
// conflicting -- and individually invalid -- values in a temp HOME,
// LoadFromReader still succeeds using only the stdin values. If it ever
// consulted the file or the environment, this would either produce
// different output or fail outright, since the ambient status address
// and retention are both refused by Load's own validation.
func TestLoadFromReaderIgnoresFileAndEnvironment(t *testing.T) {
	withCleanEnv(t)
	paths, err := config.DefaultPaths()
	if err != nil {
		t.Fatalf("DefaultPaths: %v", err)
	}

	writeConfigFile(t, paths.ConfigFile, config.Config{
		LibreLinkUpEmail:    "file@example.test",
		LibreLinkUpPassword: "file-password",
		Token:               "file-token",
		StatusAddr:          "10.0.0.5:1338", // non-loopback: Load would refuse this outright
		RetentionDays:       30,
		KeyPath:             paths.KeyFile,
	})
	writeKeyFile(t, paths.KeyFile, 'F')

	envKeyPath := filepath.Join(t.TempDir(), "env-key")
	writeKeyFile(t, envKeyPath, 'E')
	t.Setenv("CGM_RELAY_EMAIL", "env@example.test")
	t.Setenv("CGM_RELAY_PASSWORD", "env-password")
	t.Setenv("CGM_RELAY_TOKEN", "env-token")
	t.Setenv("CGM_RELAY_LISTEN_ADDR", "127.0.0.1:5555")
	t.Setenv("CGM_RELAY_DATABASE_PATH", filepath.Join(t.TempDir(), "env-readings.db"))
	t.Setenv("CGM_RELAY_KEY_PATH", envKeyPath)
	t.Setenv("CGM_RELAY_RETENTION_DAYS", "-9") // Load would refuse this outright too
	t.Setenv("CGM_RELAY_KEY", testKeyBase64('X'))

	stdinDBPath := filepath.Join(t.TempDir(), "stdin-readings.db")
	input := fmt.Sprintf(`{
  "librelinkup_email": "stdin@example.test",
  "librelinkup_password": "stdin-password",
  "token": "stdin-token",
  "listen_addr": "127.0.0.1:6666",
  "status_addr": "127.0.0.1:6667",
  "database_path": %q,
  "retention_days": 20,
  "key": %q
}`, stdinDBPath, testKeyBase64('S'))

	got, err := config.LoadFromReader(strings.NewReader(input))
	if err != nil {
		t.Fatalf("LoadFromReader: %v (want it to succeed from stdin alone, ignoring the invalid ambient file and environment)", err)
	}
	want := config.Config{
		LibreLinkUpEmail:    "stdin@example.test",
		LibreLinkUpPassword: "stdin-password",
		Token:               "stdin-token",
		ListenAddr:          "127.0.0.1:6666",
		StatusAddr:          "127.0.0.1:6667",
		DatabasePath:        stdinDBPath,
		KeyPath:             "",
		RetentionDays:       20,
		Key:                 testKeyBytes('S'),
	}
	assertConfigEqual(t, got, want)
}

// TestLoadFromReaderRefusesInvalid checks that malformed JSON, an
// unrecognised field, each required field missing in turn, a short key, a
// non-loopback status address, and an invalid retention are all refused
// before anything binds, naming the field, and that no case's error ever
// carries the password, the email, or the valid encryption key used
// elsewhere in the same table.
func TestLoadFromReaderRefusesInvalid(t *testing.T) {
	t.Parallel()
	const email = "leak-check@example.test"
	const password = "s3cr3t-should-never-appear-in-any-error"
	goodKey := testKeyBase64('K')
	shortKey := base64.StdEncoding.EncodeToString([]byte("too-short"))
	const shortSecret = "guessable"

	cases := []struct {
		name    string
		input   string
		wantErr string
	}{
		{
			name:    "malformed JSON",
			input:   `{"librelinkup_email": `,
			wantErr: "parse",
		},
		{
			name:    "unknown field",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "listen_adr": "100.64.0.1:1337", "key": %q}`, email, password, goodKey),
			wantErr: "listen_adr",
		},
		{
			name:    "missing email",
			input:   fmt.Sprintf(`{"librelinkup_password": %q, "token": "some-token", "retention_days": 30, "key": %q}`, password, goodKey),
			wantErr: "email",
		},
		{
			name:    "missing password",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "token": "some-token", "retention_days": 30, "key": %q}`, email, goodKey),
			wantErr: "password",
		},
		{
			name:    "missing token",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "retention_days": 30, "key": %q}`, email, password, goodKey),
			wantErr: "token",
		},
		{
			name:    "missing key",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "retention_days": 30}`, email, password),
			wantErr: "encryption key",
		},
		{
			name:    "short key",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "retention_days": 30, "key": %q}`, email, password, shortKey),
			wantErr: "key",
		},
		{
			name:    "non-loopback status address",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "status_addr": "10.0.0.5:1338", "retention_days": 30, "key": %q}`, email, password, goodKey),
			wantErr: "status_addr",
		},
		{
			name:    "status_secret too short to be a secret",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "status_secret": %q, "key": %q}`, email, password, shortSecret, goodKey),
			wantErr: "status_secret",
		},
		{
			name:    "retention zero",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "retention_days": 0, "key": %q}`, email, password, goodKey),
			wantErr: "retention_days",
		},
		{
			name:    "retention negative",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "retention_days": -5, "key": %q}`, email, password, goodKey),
			wantErr: "retention_days",
		},
		{
			name:    "librelinkup_base_url plain http to a non-loopback host",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "librelinkup_base_url": "http://10.0.0.5:8080", "key": %q}`, email, password, goodKey),
			wantErr: "librelinkup_base_url",
		},
		{
			name:    "librelinkup_base_url unsupported scheme",
			input:   fmt.Sprintf(`{"librelinkup_email": %q, "librelinkup_password": %q, "token": "some-token", "librelinkup_base_url": "ftp://example.test", "key": %q}`, email, password, goodKey),
			wantErr: "librelinkup_base_url",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			_, err := config.LoadFromReader(strings.NewReader(c.input))
			if err == nil {
				t.Fatal("LoadFromReader succeeded, want a refusal")
			}
			if !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("error = %v, want it to mention %q", err, c.wantErr)
			}
			if strings.Contains(err.Error(), password) {
				t.Errorf("error leaks the password: %v", err)
			}
			if strings.Contains(err.Error(), email) {
				t.Errorf("error leaks the email: %v", err)
			}
			if strings.Contains(err.Error(), goodKey) {
				t.Errorf("error leaks the encryption key: %v", err)
			}
			if strings.Contains(err.Error(), shortSecret) {
				t.Errorf("error leaks the status secret: %v", err)
			}
		})
	}
}
