package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

// LoadFromReader decodes a full runtime configuration from r: a single
// JSON object using the same field names as the on-disk config file, plus
// a "key" field carrying the store encryption key as standard base64, in
// place of a key file. It is `cgm-relay serve --config-stdin`'s own entry
// point: unlike Load, it never consults the config file, any CGM_RELAY_*
// environment variable, or a key file, so a caller holding the
// configuration somewhere else -- a system keychain, say -- can hand it
// over without ever writing it to disk or the process environment.
// key_path, if present in the JSON, is ignored: the key always comes from
// "key" instead, and the returned Config's KeyPath is left empty.
// Defaults and every validation Load applies -- the default database path
// under DefaultPaths, the required fields, the key length, retention of
// at least one day, and a loopback-only status address -- apply the same
// way here, sharing the same helpers. A field name it does not recognise,
// or anything after the object, is refused rather than ignored.
func LoadFromReader(r io.Reader) (Config, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return Config{}, fmt.Errorf("config: read stdin config: %w", err)
	}

	// The caller is a program rather than a person editing a file, so a
	// misspelt field is a bug on its side; ignoring it would fall back to a
	// default without a word (a misspelt listen_addr binds loopback only).
	// The outer Key and RetentionDays shadow Config's own: Key is excluded
	// from Config's JSON entirely, and a pointer is the only way to tell an
	// absent retention_days from an explicit zero.
	var in struct {
		Config
		Key           *string `json:"key"`
		RetentionDays *int    `json:"retention_days"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return Config{}, fmt.Errorf("config: parse stdin config: %w", err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return Config{}, errors.New("config: parse stdin config: unexpected data after the JSON object")
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
