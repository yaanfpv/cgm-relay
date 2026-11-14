package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strings"
)

// LoadFromReader decodes a full runtime configuration from r: a single
// JSON object using the same field names as the on-disk config file, plus
// a "key" field carrying the store encryption key as standard base64, in
// place of a key file, and an optional "status_secret" the status listener
// then requires of its callers (see Config.StatusSecret). It is
// `cgm-relay serve --config-stdin`'s own entry point: unlike Load, it
// never consults the config file, any CGM_RELAY_* environment variable, or
// a key file, so a caller holding the configuration somewhere else -- a
// system keychain, say -- can hand it over without ever writing it to disk
// or the process environment.
// An optional "tailscale_state_dir" and "tailscale_hostname" turn on the
// built-in Tailscale route (see Config.TailscaleStateDir).
// key_path, if present in the JSON, is ignored: the key always comes from
// "key" instead, and the returned Config's KeyPath is left empty.
// Defaults and every validation Load applies -- the default database path
// under DefaultPaths, the required fields, the key length, retention of
// at least one day, a loopback-only status address, and an allowed
// LibreLinkUp base URL -- apply the same way here, sharing the same
// helpers. A field name it does not recognise is refused rather than
// ignored.
//
// LoadFromReader decodes exactly one JSON value and returns as soon as it
// has one: it never reads r to EOF first. r is the caller's own stdin, a
// lifeline held open for as long as the caller is running; its own later
// EOF is a separate shutdown signal the caller (cmd/cgm-relay) watches
// for, not something this decode step waits for or refuses.
func LoadFromReader(r io.Reader) (Config, error) {
	// The caller is a program rather than a person editing a file, so a
	// misspelt field is a bug on its side; ignoring it would fall back to a
	// default without a word (a misspelt listen_addr binds loopback only).
	// The outer Key, StatusSecret and RetentionDays shadow Config's own: Key
	// and StatusSecret are excluded from Config's JSON entirely, and a
	// pointer is the only way to tell an absent retention_days from an
	// explicit zero.
	var in struct {
		Config
		Key           *string `json:"key"`
		RetentionDays *int    `json:"retention_days"`
		StatusSecret  string  `json:"status_secret"`
		// The built-in Tailscale route's two settings are stdin-only, like
		// StatusSecret, so they never reach the config file.
		TailscaleStateDir string `json:"tailscale_state_dir"`
		TailscaleHostname string `json:"tailscale_hostname"`
	}
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return Config{}, fmt.Errorf("config: parse stdin config: %w", err)
	}

	cfg := in.Config
	cfg.KeyPath = ""
	if in.RetentionDays != nil {
		if *in.RetentionDays < 1 {
			return Config{}, fmt.Errorf("config: stdin config: retention_days must be at least 1 day, got %d", *in.RetentionDays)
		}
		cfg.RetentionDays = *in.RetentionDays
	}
	if cfg.StatusAddr != "" && !IsLoopbackAddr(cfg.StatusAddr) {
		return Config{}, fmt.Errorf("config: stdin config: status_addr must be a loopback address, got %q", cfg.StatusAddr)
	}
	if in.StatusSecret != "" && len(in.StatusSecret) < minStatusSecretLength {
		return Config{}, fmt.Errorf("config: stdin config: status_secret must be at least %d characters", minStatusSecretLength)
	}
	cfg.StatusSecret = in.StatusSecret
	if err := validateTailscale(in.TailscaleStateDir, in.TailscaleHostname); err != nil {
		return Config{}, fmt.Errorf("config: stdin config: %w", err)
	}
	cfg.TailscaleStateDir = in.TailscaleStateDir
	cfg.TailscaleHostname = in.TailscaleHostname
	if !IsAllowedLibreLinkUpBaseURL(cfg.LibreLinkUpBaseURL) {
		return Config{}, fmt.Errorf("config: stdin config: librelinkup_base_url must be https, or plain http to a loopback address, got %q", cfg.LibreLinkUpBaseURL)
	}

	// An empty path would open SQLite's temporary database, which is
	// deleted on close, so every restart would silently lose every reading.
	if cfg.DatabasePath == "" {
		paths, err := DefaultPaths()
		if err != nil {
			return Config{}, err
		}
		cfg.DatabasePath = paths.DatabaseFile
	}
	cfg = applyDefaults(cfg)

	if in.Key != nil {
		key, err := decodeKey(*in.Key)
		if err != nil {
			return Config{}, fmt.Errorf("config: stdin config: key: %w", err)
		}
		cfg.Key = key
	}

	if missing := missingFields(cfg); len(missing) > 0 {
		return Config{}, fmt.Errorf("config: stdin config: missing %s", strings.Join(missing, ", "))
	}

	return cfg, nil
}

// validateTailscale checks the built-in route's two settings: both or
// neither, the directory absolute, and the hostname one lowercase DNS label.
// The hostname becomes part of a name published in public certificate logs,
// so it is held to a plain label rather than anything a person typed.
func validateTailscale(stateDir, hostname string) error {
	if stateDir == "" && hostname == "" {
		return nil
	}
	if stateDir == "" {
		return errors.New("tailscale_hostname needs tailscale_state_dir")
	}
	if !filepath.IsAbs(stateDir) {
		return fmt.Errorf("tailscale_state_dir must be an absolute path, got %q", stateDir)
	}
	if !genericHostname.MatchString(hostname) {
		return fmt.Errorf("tailscale_hostname must be one lowercase DNS label of letters, digits and hyphens, got %q", hostname)
	}
	return nil
}

var genericHostname = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
