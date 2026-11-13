// Package config resolves cgm-relay's on-disk configuration: which
// LibreLinkUp account to poll, the generated Nightscout access token, and
// where the relay keeps its encryption key, its reading database, and how
// long it retains readings.
//
// A fresh installation is configured once with `cgm-relay setup`, which
// writes a JSON config file and a separate key file under
// os.UserConfigDir()/cgm-relay. Every field can also be set with an
// environment variable, which always takes priority over the file:
//
//	CGM_RELAY_EMAIL           LibreLinkUp account email
//	CGM_RELAY_PASSWORD        LibreLinkUp account password
//	CGM_RELAY_TOKEN           Nightscout API access token
//	CGM_RELAY_LISTEN_ADDR     address the relay listens on
//	CGM_RELAY_STATUS_ADDR     address the relay's local status endpoint
//	                          listens on; must always be loopback
//	CGM_RELAY_DATABASE_PATH   path to the reading database
//	CGM_RELAY_KEY_PATH        path to the store encryption key file
//	CGM_RELAY_RETENTION_DAYS  days of readings to keep
//	CGM_RELAY_KEY             the store encryption key itself, base64,
//	                          in place of a key file (for containers)
//	CGM_RELAY_LIBRELINKUP_BASE_URL
//	                          point sign-in and every fetch at something
//	                          other than the official LibreLinkUp
//	                          service; see Config.LibreLinkUpBaseURL
//
// See LoadFromReader for the alternate path `cgm-relay serve
// --config-stdin` uses: a single JSON object piped on stdin, in place of
// the config file and every environment variable above.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/store"
)

// DefaultListenAddr is the address the relay listens on when nothing else
// sets one: localhost only, on Nightscout's conventional port, so a fresh
// install never exposes itself to the network by accident.
const DefaultListenAddr = "127.0.0.1:1337"

// DefaultStatusAddr is the address the relay's local status endpoint
// listens on when nothing else sets one. Unlike ListenAddr, this one can
// never be widened: IsLoopbackAddr enforces loopback-only regardless of what
// a caller configures, whether or not a StatusSecret guards it.
const DefaultStatusAddr = "127.0.0.1:1338"

// StatusSecretHeader is the request header carrying Config.StatusSecret to
// the status listener. The macOS app's StatusFetcher and PairingCodeMinter
// must always agree with this name.
const StatusSecretHeader = "X-CGM-Relay-Status-Secret"

// minStatusSecretLength is the shortest status_secret the stdin loader
// accepts, so a caller cannot configure a guessable one by mistake.
const minStatusSecretLength = 16

// DefaultRetentionDays is how many days of readings the relay keeps when
// nothing else sets a value. It is derived from store.DefaultRetention,
// the store's own pruning contract, rather than a second literal that
// could drift from it.
const DefaultRetentionDays = int(store.DefaultRetention / (24 * time.Hour))

// keySize is the required length, in bytes, of the store encryption key
// (AES-256) and of the generated Nightscout access token.
const keySize = 32

// Config is cgm-relay's full runtime configuration.
type Config struct {
	// LibreLinkUpEmail is the LibreLinkUp account's sign-in email.
	LibreLinkUpEmail string `json:"librelinkup_email"`
	// LibreLinkUpPassword is the LibreLinkUp account's sign-in password.
	LibreLinkUpPassword string `json:"librelinkup_password"`
	// Token is the bearer token a Nightscout-compatible follower app
	// presents to read from this relay.
	Token string `json:"token"`
	// LibreLinkUpBaseURL, when set, points sign-in and every fetch at
	// something other than the official LibreLinkUp service: a
	// development-only escape for driving the relay against a fake
	// instead of a real account. Empty means the official service,
	// unchanged. IsAllowedLibreLinkUpBaseURL is the one validation every
	// source (file, environment, stdin) applies: https to any host, or
	// plain http to a loopback address only, so this can never be
	// pointed at a plaintext endpoint on the open network.
	LibreLinkUpBaseURL string `json:"librelinkup_base_url"`
	// ListenAddr is the host:port the relay's HTTP server listens on.
	ListenAddr string `json:"listen_addr"`
	// StatusAddr is the host:port the relay's local status endpoint
	// listens on. It must always resolve to a loopback address; Load
	// refuses any other value, from either the file or the environment.
	StatusAddr string `json:"status_addr"`
	// DatabasePath is where the encrypted reading database lives.
	DatabasePath string `json:"database_path"`
	// KeyPath is where the store's encryption key file lives.
	KeyPath string `json:"key_path"`
	// RetentionDays is how many days of readings the relay keeps. Zero
	// means "use the default"; Load refuses any explicitly supplied
	// value below one day, from either the file or the environment.
	RetentionDays int `json:"retention_days"`
	// Key is the resolved 32-byte store encryption key: decoded from
	// CGM_RELAY_KEY if that is set, otherwise read and decoded from the
	// file at KeyPath. Load and Setup populate it; it is never written
	// to the config file.
	Key []byte `json:"-"`
	// StatusSecret, when set, is the per-launch secret the status listener
	// requires in the StatusSecretHeader request header on /status and
	// /pairing. Only `serve --config-stdin` sets it (the Mac app generates
	// one per engine launch); the file and environment never carry one, so a
	// headless install has none and the relay refuses to mint pairing codes.
	// It is never written to the config file and never logged.
	StatusSecret string `json:"-"`
}

// Paths are the on-disk locations Setup writes to and Load reads from.
type Paths struct {
	// Dir is the directory holding the config file and the key file.
	Dir string
	// ConfigFile is the path to the JSON config file.
	ConfigFile string
	// KeyFile is the path to the key file.
	KeyFile string
	// DataDir is the directory holding the reading database, kept out
	// of Dir so the key is never beside the data it protects.
	DataDir string
	// DatabaseFile is the default path to the reading database.
	DatabaseFile string
}

// DefaultPaths returns the locations a fresh installation uses, rooted at
// os.UserConfigDir()/cgm-relay.
func DefaultPaths() (Paths, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return Paths{}, fmt.Errorf("config: find user config directory: %w", err)
	}
	dir := filepath.Join(base, "cgm-relay")
	dataDir := filepath.Join(dir, "data")
	return Paths{
		Dir:          dir,
		ConfigFile:   filepath.Join(dir, "config.json"),
		KeyFile:      filepath.Join(dir, "key"),
		DataDir:      dataDir,
		DatabaseFile: filepath.Join(dataDir, "readings.db"),
	}, nil
}

// missingFields names every required field of cfg that is still empty,
// in a fixed order, so a caller can report them all together. ListenAddr
// and RetentionDays are never required: applyDefaults gives them a value
// before this ever runs.
func missingFields(cfg Config) []string {
	var missing []string
	if cfg.LibreLinkUpEmail == "" {
		missing = append(missing, "librelinkup email")
	}
	if cfg.LibreLinkUpPassword == "" {
		missing = append(missing, "librelinkup password")
	}
	if cfg.Token == "" {
		missing = append(missing, "token")
	}
	if len(cfg.Key) != keySize {
		missing = append(missing, "encryption key")
	}
	return missing
}

// applyDefaults fills in every field that has a sensible default and is
// still unset.
func applyDefaults(cfg Config) Config {
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = DefaultListenAddr
	}
	if cfg.StatusAddr == "" {
		cfg.StatusAddr = DefaultStatusAddr
	}
	if cfg.RetentionDays == 0 {
		cfg.RetentionDays = DefaultRetentionDays
	}
	return cfg
}

// marshalFile renders cfg as the JSON stored in the config file. Key is
// deliberately excluded by its own json:"-" tag: it lives only in the key
// file, or in CGM_RELAY_KEY, never beside the account credentials.
func marshalFile(cfg Config) ([]byte, error) {
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("config: encode config file: %w", err)
	}
	return append(b, '\n'), nil
}
