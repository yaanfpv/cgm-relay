package config_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yaanfpv/cgm-relay/internal/config"
)

// writeConfigFile marshals cfg as the config file Load reads, at path,
// creating its directory (mode 0700) if needed.
func writeConfigFile(t *testing.T, path string, cfg config.Config) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal config: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// writeConfigFileRaw writes raw literally to the config file, creating
// its directory (mode 0700) if needed. json.Marshal of a config.Config
// literal can't express an explicit zero or negative retention_days --
// Go's int has no way to distinguish "explicitly 0" from "left unset" --
// so the retention test below writes the exact bytes it needs directly.
func writeConfigFileRaw(t *testing.T, path string, raw string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// writeKeyFile writes the base64 encoding of a 32-byte key filled with
// b to path, creating its directory (mode 0700) if needed.
func writeKeyFile(t *testing.T, path string, b byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	contents := testKeyBase64(b) + "\n"
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// TestLoad exercises Load across the config file alone, the environment
// alone, both together (environment must win), and each required piece
// missing in turn.
func TestLoad(t *testing.T) {
	type envMap = map[string]string

	t.Run("file only", func(t *testing.T) {
		withCleanEnv(t)
		paths, err := config.DefaultPaths()
		if err != nil {
			t.Fatalf("DefaultPaths: %v", err)
		}
		writeConfigFile(t, paths.ConfigFile, config.Config{
			LibreLinkUpEmail:    "file@example.test",
			LibreLinkUpPassword: "file-password",
			Token:               "file-token",
			ListenAddr:          "127.0.0.1:9999",
			StatusAddr:          "127.0.0.1:9998",
			DatabasePath:        paths.DatabaseFile,
			KeyPath:             paths.KeyFile,
			RetentionDays:       30,
		})
		writeKeyFile(t, paths.KeyFile, 'K')

		got, err := config.Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		want := config.Config{
			LibreLinkUpEmail:    "file@example.test",
			LibreLinkUpPassword: "file-password",
			Token:               "file-token",
			ListenAddr:          "127.0.0.1:9999",
			StatusAddr:          "127.0.0.1:9998",
			DatabasePath:        paths.DatabaseFile,
			KeyPath:             paths.KeyFile,
			RetentionDays:       30,
			Key:                 testKeyBytes('K'),
		}
		assertConfigEqual(t, got, want)
	})

	t.Run("env only", func(t *testing.T) {
		withCleanEnv(t)
		paths, err := config.DefaultPaths()
		if err != nil {
			t.Fatalf("DefaultPaths: %v", err)
		}
		dbPath := filepath.Join(t.TempDir(), "env-readings.db")
		env := envMap{
			"CGM_RELAY_EMAIL":          "env@example.test",
			"CGM_RELAY_PASSWORD":       "env-password",
			"CGM_RELAY_TOKEN":          "env-token",
			"CGM_RELAY_LISTEN_ADDR":    "127.0.0.1:8888",
			"CGM_RELAY_STATUS_ADDR":    "127.0.0.1:8887",
			"CGM_RELAY_DATABASE_PATH":  dbPath,
			"CGM_RELAY_RETENTION_DAYS": "45",
			"CGM_RELAY_KEY":            testKeyBase64('E'),
		}
		for name, value := range env {
			t.Setenv(name, value)
		}

		got, err := config.Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		want := config.Config{
			LibreLinkUpEmail:    "env@example.test",
			LibreLinkUpPassword: "env-password",
			Token:               "env-token",
			ListenAddr:          "127.0.0.1:8888",
			StatusAddr:          "127.0.0.1:8887",
			DatabasePath:        dbPath,
			KeyPath:             paths.KeyFile, // no CGM_RELAY_KEY_PATH set, so this stays the default
			RetentionDays:       45,
			Key:                 testKeyBytes('E'),
		}
		assertConfigEqual(t, got, want)
	})

	t.Run("both, environment wins", func(t *testing.T) {
		withCleanEnv(t)
		paths, err := config.DefaultPaths()
		if err != nil {
			t.Fatalf("DefaultPaths: %v", err)
		}
		fileKeyPath := filepath.Join(paths.Dir, "file-key")
		envKeyPath := filepath.Join(paths.Dir, "env-key")
		writeConfigFile(t, paths.ConfigFile, config.Config{
			LibreLinkUpEmail:    "file@example.test",
			LibreLinkUpPassword: "file-password",
			Token:               "file-token",
			ListenAddr:          "127.0.0.1:9999",
			StatusAddr:          "127.0.0.1:9998",
			DatabasePath:        filepath.Join(paths.Dir, "file-readings.db"),
			KeyPath:             fileKeyPath,
			RetentionDays:       30,
		})
		writeKeyFile(t, fileKeyPath, 'F')
		writeKeyFile(t, envKeyPath, 'X') // env overrides KeyPath too; this file is a decoy

		env := envMap{
			"CGM_RELAY_EMAIL":          "env@example.test",
			"CGM_RELAY_PASSWORD":       "env-password",
			"CGM_RELAY_TOKEN":          "env-token",
			"CGM_RELAY_LISTEN_ADDR":    "127.0.0.1:8888",
			"CGM_RELAY_STATUS_ADDR":    "127.0.0.1:8887",
			"CGM_RELAY_DATABASE_PATH":  filepath.Join(paths.Dir, "env-readings.db"),
			"CGM_RELAY_KEY_PATH":       envKeyPath,
			"CGM_RELAY_RETENTION_DAYS": "45",
			"CGM_RELAY_KEY":            testKeyBase64('E'), // wins over the file at envKeyPath too
		}
		for name, value := range env {
			t.Setenv(name, value)
		}

		got, err := config.Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		want := config.Config{
			LibreLinkUpEmail:    "env@example.test",
			LibreLinkUpPassword: "env-password",
			Token:               "env-token",
			ListenAddr:          "127.0.0.1:8888",
			StatusAddr:          "127.0.0.1:8887",
			DatabasePath:        filepath.Join(paths.Dir, "env-readings.db"),
			KeyPath:             envKeyPath,
			RetentionDays:       45,
			Key:                 testKeyBytes('E'),
		}
		assertConfigEqual(t, got, want)
	})

	missingCases := []struct {
		name          string
		mutate        func(cfg *config.Config)
		wantNoKeyFile bool
		wantErr       string
	}{
		{
			name:    "missing email",
			mutate:  func(cfg *config.Config) { cfg.LibreLinkUpEmail = "" },
			wantErr: "email",
		},
		{
			name:    "missing password",
			mutate:  func(cfg *config.Config) { cfg.LibreLinkUpPassword = "" },
			wantErr: "password",
		},
		{
			name:    "missing token",
			mutate:  func(cfg *config.Config) { cfg.Token = "" },
			wantErr: "token",
		},
		{
			name:          "missing encryption key",
			mutate:        func(cfg *config.Config) {},
			wantNoKeyFile: true,
			wantErr:       "encryption key",
		},
	}
	for _, c := range missingCases {
		t.Run(c.name, func(t *testing.T) {
			withCleanEnv(t)
			paths, err := config.DefaultPaths()
			if err != nil {
				t.Fatalf("DefaultPaths: %v", err)
			}
			cfg := config.Config{
				LibreLinkUpEmail:    "person@example.test",
				LibreLinkUpPassword: "some-password",
				Token:               "some-token",
				KeyPath:             paths.KeyFile,
				RetentionDays:       30, // a valid value, so only the mutated field is under test
			}
			c.mutate(&cfg)
			writeConfigFile(t, paths.ConfigFile, cfg)
			if !c.wantNoKeyFile {
				writeKeyFile(t, paths.KeyFile, 'K')
			}

			_, err = config.Load()
			if err == nil {
				t.Fatal("Load succeeded, want an error naming the missing piece")
			}
			if !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("error = %v, want it to mention %q", err, c.wantErr)
			}
		})
	}

	t.Run("malformed CGM_RELAY_KEY names itself, not the value", func(t *testing.T) {
		withCleanEnv(t)
		paths, err := config.DefaultPaths()
		if err != nil {
			t.Fatalf("DefaultPaths: %v", err)
		}
		writeConfigFile(t, paths.ConfigFile, config.Config{
			LibreLinkUpEmail:    "person@example.test",
			LibreLinkUpPassword: "some-password",
			Token:               "some-token",
			RetentionDays:       30, // a valid value, so only the malformed key is under test
		})
		t.Setenv("CGM_RELAY_KEY", "not-valid-base64-key!!")

		_, err = config.Load()
		if err == nil {
			t.Fatal("Load succeeded with a malformed CGM_RELAY_KEY, want an error")
		}
		if !strings.Contains(err.Error(), "CGM_RELAY_KEY") {
			t.Errorf("error = %v, want it to name CGM_RELAY_KEY", err)
		}
		if strings.Contains(err.Error(), "not-valid-base64-key!!") {
			t.Error("error echoes the malformed key value")
		}
	})
}

// TestLoadRefusesInvalidRetention checks that a non-positive retention is
// refused: store.Prune's cutoff would otherwise land in the future and
// delete every reading. An explicit value below one day, from either the
// file or the environment, must be refused naming the setting, and an
// absent value must default to store.DefaultRetention (15 days) rather
// than a second, independent literal.
func TestLoadRefusesInvalidRetention(t *testing.T) {
	t.Run("absent defaults to 15", func(t *testing.T) {
		withCleanEnv(t)
		t.Setenv("CGM_RELAY_EMAIL", "person@example.test")
		t.Setenv("CGM_RELAY_PASSWORD", "some-password")
		t.Setenv("CGM_RELAY_TOKEN", "some-token")
		t.Setenv("CGM_RELAY_KEY", testKeyBase64('K'))

		got, err := config.Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if got.RetentionDays != 15 {
			t.Errorf("RetentionDays = %d, want 15", got.RetentionDays)
		}
		if got.RetentionDays != config.DefaultRetentionDays {
			t.Errorf("RetentionDays = %d, want it to equal config.DefaultRetentionDays (%d)", got.RetentionDays, config.DefaultRetentionDays)
		}
	})

	cases := []struct {
		name    string
		rawFile string // "" = write a valid file instead (env is under test)
		envDays string // "" = do not set the environment override
		wantErr string
	}{
		{
			name: "file -5",
			rawFile: `{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "retention_days": -5
}`,
			wantErr: "retention_days",
		},
		{
			name: "file 0",
			rawFile: `{
  "librelinkup_email": "person@example.test",
  "librelinkup_password": "some-password",
  "token": "some-token",
  "retention_days": 0
}`,
			wantErr: "retention_days",
		},
		{
			name:    "env -5",
			envDays: "-5",
			wantErr: "CGM_RELAY_RETENTION_DAYS",
		},
		{
			name:    "env 0",
			envDays: "0",
			wantErr: "CGM_RELAY_RETENTION_DAYS",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withCleanEnv(t)
			paths, err := config.DefaultPaths()
			if err != nil {
				t.Fatalf("DefaultPaths: %v", err)
			}
			if c.rawFile != "" {
				writeConfigFileRaw(t, paths.ConfigFile, c.rawFile)
			} else {
				writeConfigFile(t, paths.ConfigFile, config.Config{
					LibreLinkUpEmail:    "person@example.test",
					LibreLinkUpPassword: "some-password",
					Token:               "some-token",
					RetentionDays:       30,
				})
			}
			writeKeyFile(t, paths.KeyFile, 'K')
			if c.envDays != "" {
				t.Setenv("CGM_RELAY_RETENTION_DAYS", c.envDays)
			}

			_, err = config.Load()
			if err == nil {
				t.Fatal("Load succeeded with an invalid retention, want an error")
			}
			if !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("error = %v, want it to mention %q", err, c.wantErr)
			}
		})
	}
}

// TestLoadDefaultsListenAddrToLocalhost checks that, with everything else
// supplied but no listen address set anywhere, Load defaults to loopback
// on the documented port -- never a wildcard, an empty host, or a bare
// ":port".
func TestLoadDefaultsListenAddrToLocalhost(t *testing.T) {
	withCleanEnv(t)
	t.Setenv("CGM_RELAY_EMAIL", "person@example.test")
	t.Setenv("CGM_RELAY_PASSWORD", "some-password")
	t.Setenv("CGM_RELAY_TOKEN", "some-token")
	t.Setenv("CGM_RELAY_KEY", testKeyBase64('K'))

	got, err := config.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	const wantAddr = "127.0.0.1:1337"
	if got.ListenAddr != wantAddr {
		t.Errorf("ListenAddr = %q, want %q", got.ListenAddr, wantAddr)
	}
	if got.ListenAddr != config.DefaultListenAddr {
		t.Errorf("ListenAddr = %q, want it to equal config.DefaultListenAddr (%q)", got.ListenAddr, config.DefaultListenAddr)
	}
	if strings.HasPrefix(got.ListenAddr, "0.0.0.0") {
		t.Errorf("ListenAddr = %q, defaults to a wildcard address", got.ListenAddr)
	}
	if strings.HasPrefix(got.ListenAddr, ":") {
		t.Errorf("ListenAddr = %q, defaults to an empty host", got.ListenAddr)
	}
}

// TestLoadDefaultsStatusAddrToLocalhost checks that, with everything else
// supplied but no status address set anywhere, Load defaults to loopback
// on the documented port.
func TestLoadDefaultsStatusAddrToLocalhost(t *testing.T) {
	withCleanEnv(t)
	t.Setenv("CGM_RELAY_EMAIL", "person@example.test")
	t.Setenv("CGM_RELAY_PASSWORD", "some-password")
	t.Setenv("CGM_RELAY_TOKEN", "some-token")
	t.Setenv("CGM_RELAY_KEY", testKeyBase64('K'))

	got, err := config.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	const wantAddr = "127.0.0.1:1338"
	if got.StatusAddr != wantAddr {
		t.Errorf("StatusAddr = %q, want %q", got.StatusAddr, wantAddr)
	}
	if got.StatusAddr != config.DefaultStatusAddr {
		t.Errorf("StatusAddr = %q, want it to equal config.DefaultStatusAddr (%q)", got.StatusAddr, config.DefaultStatusAddr)
	}
}

// TestLoadRefusesNonLoopbackStatusAddr checks that a non-loopback status
// address is refused: it would otherwise expose the relay's
// unauthenticated status endpoint to the network. An explicit value that
// does not resolve to loopback, from either the file or the environment,
// must be refused naming the setting.
func TestLoadRefusesNonLoopbackStatusAddr(t *testing.T) {
	cases := []struct {
		name       string
		statusAddr string // set on the file's Config; ignored when envAddr != ""
		envAddr    string // "" = do not set the environment override
		wantErr    string
	}{
		{name: "file wildcard", statusAddr: "0.0.0.0:1338", wantErr: "status_addr"},
		{name: "file non-loopback host", statusAddr: "10.0.0.5:1338", wantErr: "status_addr"},
		{name: "env wildcard", envAddr: "0.0.0.0:1338", wantErr: "CGM_RELAY_STATUS_ADDR"},
		{name: "env non-loopback host", envAddr: "192.168.1.5:1338", wantErr: "CGM_RELAY_STATUS_ADDR"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withCleanEnv(t)
			paths, err := config.DefaultPaths()
			if err != nil {
				t.Fatalf("DefaultPaths: %v", err)
			}
			cfg := config.Config{
				LibreLinkUpEmail:    "person@example.test",
				LibreLinkUpPassword: "some-password",
				Token:               "some-token",
				RetentionDays:       30,
			}
			if c.statusAddr != "" {
				cfg.StatusAddr = c.statusAddr
			}
			writeConfigFile(t, paths.ConfigFile, cfg)
			writeKeyFile(t, paths.KeyFile, 'K')
			if c.envAddr != "" {
				t.Setenv("CGM_RELAY_STATUS_ADDR", c.envAddr)
			}

			_, err = config.Load()
			if err == nil {
				t.Fatal("Load succeeded with a non-loopback status address, want an error")
			}
			if !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("error = %v, want it to mention %q", err, c.wantErr)
			}
		})
	}
}

// TestLoadLibreLinkUpBaseURL checks that librelinkup_base_url defaults to
// empty (the official LibreLinkUp service, unchanged) and can be set from
// either the file or the environment, with the environment winning when
// both are present.
func TestLoadLibreLinkUpBaseURL(t *testing.T) {
	t.Run("absent defaults to empty", func(t *testing.T) {
		withCleanEnv(t)
		t.Setenv("CGM_RELAY_EMAIL", "person@example.test")
		t.Setenv("CGM_RELAY_PASSWORD", "some-password")
		t.Setenv("CGM_RELAY_TOKEN", "some-token")
		t.Setenv("CGM_RELAY_KEY", testKeyBase64('K'))

		got, err := config.Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if got.LibreLinkUpBaseURL != "" {
			t.Errorf("LibreLinkUpBaseURL = %q, want empty", got.LibreLinkUpBaseURL)
		}
	})

	t.Run("set from the file", func(t *testing.T) {
		withCleanEnv(t)
		paths, err := config.DefaultPaths()
		if err != nil {
			t.Fatalf("DefaultPaths: %v", err)
		}
		writeConfigFile(t, paths.ConfigFile, config.Config{
			LibreLinkUpEmail:    "person@example.test",
			LibreLinkUpPassword: "some-password",
			Token:               "some-token",
			LibreLinkUpBaseURL:  "https://fake.example.test",
			RetentionDays:       30,
		})
		writeKeyFile(t, paths.KeyFile, 'K')

		got, err := config.Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if got.LibreLinkUpBaseURL != "https://fake.example.test" {
			t.Errorf("LibreLinkUpBaseURL = %q, want %q", got.LibreLinkUpBaseURL, "https://fake.example.test")
		}
	})

	t.Run("environment wins over the file", func(t *testing.T) {
		withCleanEnv(t)
		paths, err := config.DefaultPaths()
		if err != nil {
			t.Fatalf("DefaultPaths: %v", err)
		}
		writeConfigFile(t, paths.ConfigFile, config.Config{
			LibreLinkUpEmail:    "person@example.test",
			LibreLinkUpPassword: "some-password",
			Token:               "some-token",
			LibreLinkUpBaseURL:  "https://file.example.test",
			RetentionDays:       30,
		})
		writeKeyFile(t, paths.KeyFile, 'K')
		t.Setenv("CGM_RELAY_LIBRELINKUP_BASE_URL", "http://127.0.0.1:9999")

		got, err := config.Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if got.LibreLinkUpBaseURL != "http://127.0.0.1:9999" {
			t.Errorf("LibreLinkUpBaseURL = %q, want %q", got.LibreLinkUpBaseURL, "http://127.0.0.1:9999")
		}
	})
}

// TestLoadRefusesInvalidLibreLinkUpBaseURL checks that a librelinkup_base_url
// this relay is not willing to sign in and fetch against is refused
// outright, from either the file or the environment, naming the setting.
func TestLoadRefusesInvalidLibreLinkUpBaseURL(t *testing.T) {
	cases := []struct {
		name      string
		fileValue string // set on the file's Config; ignored when envValue != ""
		envValue  string // "" = do not set the environment override
		wantErr   string
	}{
		{name: "file plain http to a non-loopback host", fileValue: "http://10.0.0.5:8080", wantErr: "librelinkup_base_url"},
		{name: "file unsupported scheme", fileValue: "ftp://example.test", wantErr: "librelinkup_base_url"},
		{name: "file malformed URL", fileValue: "not a url", wantErr: "librelinkup_base_url"},
		{name: "env plain http to a non-loopback host", envValue: "http://192.168.1.5:8080", wantErr: "CGM_RELAY_LIBRELINKUP_BASE_URL"},
		{name: "env unsupported scheme", envValue: "ftp://example.test", wantErr: "CGM_RELAY_LIBRELINKUP_BASE_URL"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withCleanEnv(t)
			paths, err := config.DefaultPaths()
			if err != nil {
				t.Fatalf("DefaultPaths: %v", err)
			}
			cfg := config.Config{
				LibreLinkUpEmail:    "person@example.test",
				LibreLinkUpPassword: "some-password",
				Token:               "some-token",
				RetentionDays:       30,
			}
			if c.fileValue != "" {
				cfg.LibreLinkUpBaseURL = c.fileValue
			}
			writeConfigFile(t, paths.ConfigFile, cfg)
			writeKeyFile(t, paths.KeyFile, 'K')
			if c.envValue != "" {
				t.Setenv("CGM_RELAY_LIBRELINKUP_BASE_URL", c.envValue)
			}

			_, err = config.Load()
			if err == nil {
				t.Fatal("Load succeeded with a disallowed librelinkup_base_url, want an error")
			}
			if !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("error = %v, want it to mention %q", err, c.wantErr)
			}
		})
	}
}

// TestIsAllowedLibreLinkUpBaseURL checks the validation Load, applyEnvOverrides
// and LoadFromReader all share: empty, https to any host, and plain http
// to a loopback address are allowed; every other scheme, a malformed URL,
// and plain http to a non-loopback host are refused.
func TestIsAllowedLibreLinkUpBaseURL(t *testing.T) {
	cases := []struct {
		value string
		want  bool
	}{
		{"", true},
		{"https://api.libreview.io", true},
		{"https://fake.example.test", true},
		{"http://127.0.0.1:9999", true},
		{"http://localhost:9999", true},
		{"http://[::1]:9999", true},
		{"http://10.0.0.5:9999", false},
		{"http://example.test", false},
		{"ftp://example.test", false},
		{"not a url", false},
		{"api.libreview.io", false}, // no scheme at all
	}
	for _, c := range cases {
		if got := config.IsAllowedLibreLinkUpBaseURL(c.value); got != c.want {
			t.Errorf("IsAllowedLibreLinkUpBaseURL(%q) = %v, want %v", c.value, got, c.want)
		}
	}
}

// TestIsLoopbackAddr checks the loopback classifier Load and relay.Run
// both share, across the forms a config value or an environment variable
// can actually take.
func TestIsLoopbackAddr(t *testing.T) {
	cases := []struct {
		addr string
		want bool
	}{
		{"127.0.0.1:1338", true},
		{"127.5.5.5:1338", true},
		{"localhost:1338", true},
		{"[::1]:1338", true},
		{"0.0.0.0:1338", false},
		{"10.0.0.5:1338", false},
		{"192.168.1.5:1338", false},
		{":1338", false},
		{"[::]:1338", false},
	}
	for _, c := range cases {
		if got := config.IsLoopbackAddr(c.addr); got != c.want {
			t.Errorf("IsLoopbackAddr(%q) = %v, want %v", c.addr, got, c.want)
		}
	}
}

func assertConfigEqual(t *testing.T, got, want config.Config) {
	t.Helper()
	if got.LibreLinkUpEmail != want.LibreLinkUpEmail {
		t.Errorf("LibreLinkUpEmail = %q, want %q", got.LibreLinkUpEmail, want.LibreLinkUpEmail)
	}
	if got.LibreLinkUpPassword != want.LibreLinkUpPassword {
		t.Errorf("LibreLinkUpPassword = %q, want %q", got.LibreLinkUpPassword, want.LibreLinkUpPassword)
	}
	if got.Token != want.Token {
		t.Errorf("Token = %q, want %q", got.Token, want.Token)
	}
	if got.ListenAddr != want.ListenAddr {
		t.Errorf("ListenAddr = %q, want %q", got.ListenAddr, want.ListenAddr)
	}
	if got.StatusAddr != want.StatusAddr {
		t.Errorf("StatusAddr = %q, want %q", got.StatusAddr, want.StatusAddr)
	}
	if got.DatabasePath != want.DatabasePath {
		t.Errorf("DatabasePath = %q, want %q", got.DatabasePath, want.DatabasePath)
	}
	if got.KeyPath != want.KeyPath {
		t.Errorf("KeyPath = %q, want %q", got.KeyPath, want.KeyPath)
	}
	if got.RetentionDays != want.RetentionDays {
		t.Errorf("RetentionDays = %d, want %d", got.RetentionDays, want.RetentionDays)
	}
	if got.LibreLinkUpBaseURL != want.LibreLinkUpBaseURL {
		t.Errorf("LibreLinkUpBaseURL = %q, want %q", got.LibreLinkUpBaseURL, want.LibreLinkUpBaseURL)
	}
	if string(got.Key) != string(want.Key) {
		t.Errorf("Key = %x, want %x", got.Key, want.Key)
	}
}
