package config_test

import (
	"encoding/base64"
	"os"
	"testing"
)

// relayEnvVars lists every CGM_RELAY_* variable config.Load and
// config.Setup consult, so a test can force a clean slate regardless of
// what the ambient environment happens to carry.
var relayEnvVars = []string{
	"CGM_RELAY_EMAIL",
	"CGM_RELAY_PASSWORD",
	"CGM_RELAY_TOKEN",
	"CGM_RELAY_LISTEN_ADDR",
	"CGM_RELAY_STATUS_ADDR",
	"CGM_RELAY_DATABASE_PATH",
	"CGM_RELAY_KEY_PATH",
	"CGM_RELAY_RETENTION_DAYS",
	"CGM_RELAY_KEY",
}

// clearRelayEnv unsets every CGM_RELAY_* variable for the life of the
// test, restoring whatever was there when it ends, so no test result
// depends on what happens to be set in the ambient environment.
func clearRelayEnv(t *testing.T) {
	t.Helper()
	for _, name := range relayEnvVars {
		prev, had := os.LookupEnv(name)
		if err := os.Unsetenv(name); err != nil {
			t.Fatalf("unsetenv %s: %v", name, err)
		}
		t.Cleanup(func() {
			if had {
				os.Setenv(name, prev)
			} else {
				os.Unsetenv(name)
			}
		})
	}
}

// withCleanEnv points os.UserConfigDir() at a fresh temp directory
// (rather than the real user's config, on either the darwin or the
// Linux resolution rule) and clears every CGM_RELAY_* variable, so a
// test never touches real configuration and never inherits an ambient
// override.
func withCleanEnv(t *testing.T) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	clearRelayEnv(t)
}

// testKeyBase64 returns the base64 encoding of a distinct, deterministic
// 32-byte key filled with b, so different tests can use different keys
// without needing real randomness.
func testKeyBase64(b byte) string {
	buf := make([]byte, 32)
	for i := range buf {
		buf[i] = b
	}
	return base64.StdEncoding.EncodeToString(buf)
}

// testKeyBytes is the decoded form of testKeyBase64(b), for comparing
// against a resolved Config.Key.
func testKeyBytes(b byte) []byte {
	buf := make([]byte, 32)
	for i := range buf {
		buf[i] = b
	}
	return buf
}
