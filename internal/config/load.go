package config

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
)

// The CGM_RELAY_* environment variable names. Every Config field has one
// except Key, whose variable (envKey) carries the key's own base64 value
// directly rather than a path, so a container can supply it with no key
// file on disk at all.
const (
	envEmail         = "CGM_RELAY_EMAIL"
	envPassword      = "CGM_RELAY_PASSWORD"
	envToken         = "CGM_RELAY_TOKEN"
	envListenAddr    = "CGM_RELAY_LISTEN_ADDR"
	envStatusAddr    = "CGM_RELAY_STATUS_ADDR"
	envDatabasePath  = "CGM_RELAY_DATABASE_PATH"
	envKeyPath       = "CGM_RELAY_KEY_PATH"
	envRetentionDays = "CGM_RELAY_RETENTION_DAYS"
	envKey           = "CGM_RELAY_KEY"
)

// Load resolves the full runtime configuration: the config file at its
// default location if one exists, overridden field by field by any
// CGM_RELAY_* environment variable, with the store encryption key
// resolved from CGM_RELAY_KEY's own base64 value or, failing that, from
// the key file the config names. Defaults fill in the listen address and
// the retention period. Load refuses, naming every piece still missing
// once the file and the environment are merged.
func Load() (Config, error) {
	paths, err := DefaultPaths()
	if err != nil {
		return Config{}, err
	}

	cfg, err := readFileConfig(paths.ConfigFile)
	if err != nil {
		return Config{}, err
	}

	if err := applyEnvOverrides(&cfg); err != nil {
		return Config{}, err
	}

	if cfg.DatabasePath == "" {
		cfg.DatabasePath = paths.DatabaseFile
	}
	if cfg.KeyPath == "" {
		cfg.KeyPath = paths.KeyFile
	}
	cfg = applyDefaults(cfg)

	key, err := resolveKey(cfg.KeyPath)
	if err != nil {
		return Config{}, err
	}
	cfg.Key = key

	if missing := missingFields(cfg); len(missing) > 0 {
		return Config{}, fmt.Errorf("config: missing %s", strings.Join(missing, ", "))
	}

	return cfg, nil
}

// readFileConfig reads and decodes the config file at path. A missing
// file is not an error: it is treated as an empty configuration, so a
// setup driven entirely by environment variables needs no file at all.
// An explicitly present retention_days below one day is refused
// immediately, naming the file: store.Prune would otherwise treat a
// negative or zero retention as a cutoff in the future and delete every
// reading.
func readFileConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Config{}, nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("config: read %s: %w", path, err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("config: parse %s: %w", path, err)
	}

	// An int cannot tell an absent retention_days from an explicit zero, so
	// presence is read separately; Config stays the one description of the file.
	var retention struct {
		Days *int `json:"retention_days"`
	}
	if err := json.Unmarshal(data, &retention); err != nil {
		return Config{}, fmt.Errorf("config: parse %s: %w", path, err)
	}
	if retention.Days != nil && *retention.Days < 1 {
		return Config{}, fmt.Errorf("config: %s: retention_days must be at least 1 day, got %d", path, *retention.Days)
	}
	if cfg.StatusAddr != "" && !IsLoopbackAddr(cfg.StatusAddr) {
		return Config{}, fmt.Errorf("config: %s: status_addr must be a loopback address, got %q", path, cfg.StatusAddr)
	}
	return cfg, nil
}

// applyEnvOverrides sets every field whose environment variable is
// present, taking priority over whatever the config file set.
func applyEnvOverrides(cfg *Config) error {
	if v, ok := os.LookupEnv(envEmail); ok {
		cfg.LibreLinkUpEmail = v
	}
	if v, ok := os.LookupEnv(envPassword); ok {
		cfg.LibreLinkUpPassword = v
	}
	if v, ok := os.LookupEnv(envToken); ok {
		cfg.Token = v
	}
	if v, ok := os.LookupEnv(envListenAddr); ok {
		cfg.ListenAddr = v
	}
	if v, ok := os.LookupEnv(envStatusAddr); ok {
		if !IsLoopbackAddr(v) {
			return fmt.Errorf("config: %s must be a loopback address, got %q", envStatusAddr, v)
		}
		cfg.StatusAddr = v
	}
	if v, ok := os.LookupEnv(envDatabasePath); ok {
		cfg.DatabasePath = v
	}
	if v, ok := os.LookupEnv(envKeyPath); ok {
		cfg.KeyPath = v
	}
	if v, ok := os.LookupEnv(envRetentionDays); ok {
		days, err := strconv.Atoi(v)
		if err != nil {
			return fmt.Errorf("config: %s %q: %w", envRetentionDays, v, err)
		}
		if days < 1 {
			return fmt.Errorf("config: %s must be at least 1 day, got %d", envRetentionDays, days)
		}
		cfg.RetentionDays = days
	}
	return nil
}

// resolveKey returns the store encryption key: CGM_RELAY_KEY's own
// base64 value if that is set, otherwise the base64 contents of the file
// at keyPath. A missing key file is not an error here: Load's own
// missing-piece check reports it as the "encryption key" being absent,
// alongside any other missing required field, rather than as a distinct
// file error.
func resolveKey(keyPath string) ([]byte, error) {
	if v, ok := os.LookupEnv(envKey); ok {
		key, err := decodeKey(v)
		if err != nil {
			return nil, fmt.Errorf("config: %s: %w", envKey, err)
		}
		return key, nil
	}

	data, err := os.ReadFile(keyPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("config: read key file %s: %w", keyPath, err)
	}
	key, err := decodeKey(strings.TrimSpace(string(data)))
	if err != nil {
		return nil, fmt.Errorf("config: key file %s: %w", keyPath, err)
	}
	return key, nil
}

// IsLoopbackAddr reports whether addr -- a "host:port" pair, or a bare
// host -- names a loopback address: 127.0.0.0/8, ::1, or the literal host
// "localhost". Load uses it to enforce that StatusAddr is always
// loopback-only; it is exported so the relay package can reuse the same
// classifier, both defensively at Run's own start and per request (a
// request's Host is not the same thing as the listener's bind address:
// DNS rebinding sends a same-origin fetch with an attacker-chosen Host
// to a loopback listener, so the status endpoint checks Host with this
// same function on every request, not only once at startup).
func IsLoopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// decodeKey base64-decodes s and checks the result is exactly keySize
// bytes. It never echoes s itself: s may be attacker- or user-supplied
// and must never reach an error message.
func decodeKey(s string) ([]byte, error) {
	key, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("decode base64: %w", err)
	}
	if len(key) != keySize {
		return nil, fmt.Errorf("must decode to %d bytes, got %d", keySize, len(key))
	}
	return key, nil
}
