package config

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/term"
)

// Setup interactively creates a fresh configuration: it asks for the
// LibreLinkUp account's email and password (masked when stdin is a
// terminal, a plain line otherwise so a script can pipe one in),
// generates a Nightscout API token, and writes the config file at its
// default location, mode 0600 in a mode 0700 directory. It never
// overwrites an existing encryption key file: one already at the default
// key path is reused as is, and a fresh key is generated and written,
// same mode, only when none exists yet -- overwriting a key in use would
// make every reading already sealed with it permanently unreadable.
// Setup refuses to overwrite an existing config file unless force is
// true; force replaces the credentials and token but never rotates the
// key. It prints the generated token to stdout exactly once, with a line
// saying where to paste it; nothing else it prints, and no error it
// returns, ever contains a secret.
func Setup(stdin *os.File, stdout io.Writer, force bool) (Config, error) {
	paths, err := DefaultPaths()
	if err != nil {
		return Config{}, err
	}

	if _, statErr := os.Stat(paths.ConfigFile); statErr == nil {
		if !force {
			return Config{}, fmt.Errorf("config: %s already exists (use --force to overwrite)", paths.ConfigFile)
		}
	} else if !os.IsNotExist(statErr) {
		return Config{}, fmt.Errorf("config: check %s: %w", paths.ConfigFile, statErr)
	}

	fmt.Fprint(stdout, "LibreLinkUp email: ")
	email, err := readLine(stdin)
	if err != nil {
		return Config{}, fmt.Errorf("config: read email: %w", err)
	}
	if email == "" {
		return Config{}, fmt.Errorf("config: LibreLinkUp email must not be empty")
	}

	fmt.Fprint(stdout, "LibreLinkUp password: ")
	password, err := readSecretLine(stdin, stdout)
	if err != nil {
		return Config{}, fmt.Errorf("config: read password: %w", err)
	}
	if password == "" {
		return Config{}, fmt.Errorf("config: LibreLinkUp password must not be empty")
	}

	token, err := randomToken()
	if err != nil {
		return Config{}, err
	}

	if err := ensureDir(paths.Dir); err != nil {
		return Config{}, err
	}
	if err := ensureDir(paths.DataDir); err != nil {
		return Config{}, err
	}

	key, reusedKey, err := loadOrCreateKey(paths.KeyFile)
	if err != nil {
		return Config{}, err
	}
	if reusedKey {
		fmt.Fprintf(stdout, "Reusing the existing encryption key at %s.\n", paths.KeyFile)
	}

	cfg := applyDefaults(Config{
		LibreLinkUpEmail:    email,
		LibreLinkUpPassword: password,
		Token:               token,
		DatabasePath:        paths.DatabaseFile,
		KeyPath:             paths.KeyFile,
	})

	data, err := marshalFile(cfg)
	if err != nil {
		return Config{}, err
	}
	if err := writeFileAtomic(paths.ConfigFile, data, 0o600); err != nil {
		return Config{}, err
	}

	cfg.Key = key

	fmt.Fprintf(stdout, "\nConfiguration written to %s.\n", paths.ConfigFile)
	fmt.Fprintln(stdout, "Nightscout API token (paste this into your follower app's API token field):")
	fmt.Fprintln(stdout, token)

	return cfg, nil
}

// readLine reads one newline-terminated line from f, one byte at a time
// so it never buffers past the newline: a later read from the same
// descriptor (a password prompt right after an email prompt) sees
// exactly what the first line left behind.
func readLine(f *os.File) (string, error) {
	var line []byte
	b := make([]byte, 1)
	for {
		n, err := f.Read(b)
		if n == 1 {
			if b[0] == '\n' {
				return strings.TrimSuffix(string(line), "\r"), nil
			}
			line = append(line, b[0])
		}
		if err != nil {
			if err == io.EOF {
				if len(line) > 0 {
					return strings.TrimSuffix(string(line), "\r"), nil
				}
				return "", fmt.Errorf("read line: %w", io.EOF)
			}
			return "", err
		}
	}
}

// readSecretLine reads a password from f: silently, with no echo, when f
// is a terminal; otherwise as a plain line, so a script can pipe one in.
func readSecretLine(f *os.File, stdout io.Writer) (string, error) {
	if term.IsTerminal(int(f.Fd())) {
		b, err := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(stdout)
		if err != nil {
			return "", err
		}
		return string(b), nil
	}
	return readLine(f)
}

// randomToken generates the Nightscout API access token: keySize random
// bytes, base64url-encoded with no padding so it drops cleanly into a URL
// or a header value.
func randomToken() (string, error) {
	b := make([]byte, keySize)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("config: generate token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// randomKey generates the store's AES-256 encryption key: keySize random
// bytes.
func randomKey() ([]byte, error) {
	b := make([]byte, keySize)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("config: generate key: %w", err)
	}
	return b, nil
}

// loadOrCreateKey returns the store encryption key at keyPath, reusing an
// existing file rather than ever overwriting it: every reading already
// sealed with the old key would become permanently unreadable the moment
// that file changed. It writes a fresh, randomly generated key only when
// keyPath does not exist yet.
func loadOrCreateKey(keyPath string) (key []byte, reused bool, err error) {
	data, statErr := os.ReadFile(keyPath)
	if statErr == nil {
		existing, decodeErr := decodeKey(strings.TrimSpace(string(data)))
		if decodeErr != nil {
			return nil, false, fmt.Errorf("config: existing key file %s: %w", keyPath, decodeErr)
		}
		return existing, true, nil
	}
	if !os.IsNotExist(statErr) {
		return nil, false, fmt.Errorf("config: read key file %s: %w", keyPath, statErr)
	}

	fresh, err := randomKey()
	if err != nil {
		return nil, false, err
	}
	contents := []byte(base64.StdEncoding.EncodeToString(fresh) + "\n")
	if err := writeFileAtomic(keyPath, contents, 0o600); err != nil {
		return nil, false, err
	}
	return fresh, false, nil
}

// ensureDir creates path if it does not exist and makes sure it ends up
// mode 0700, regardless of the process umask.
func ensureDir(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return fmt.Errorf("config: create directory %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return fmt.Errorf("config: set permissions on %s: %w", path, err)
	}
	return nil
}

// writeFileAtomic writes data to path with permission perm, via a temp
// file in the same directory and a rename, so a crash mid-write never
// leaves a partial file at path and a concurrent reader never sees one.
func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return fmt.Errorf("config: create temp file in %s: %w", dir, err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once the rename below succeeds

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("config: write %s: %w", tmpName, err)
	}
	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		return fmt.Errorf("config: set permissions on %s: %w", tmpName, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("config: close %s: %w", tmpName, err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("config: rename %s to %s: %w", tmpName, path, err)
	}
	return nil
}
