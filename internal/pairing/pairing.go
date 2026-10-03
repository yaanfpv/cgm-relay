// Package pairing lets a person connect a follower app to the relay without
// typing its access token. The Mac app mints a short-lived pairing code over
// the loopback-only status endpoint and shows it in a QR code that points at
// the relay's own address; a phone that opens that address gets a page with
// every value each follower app asks for, each with a Copy button. The token
// itself is never part of any URL.
package pairing

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"sync"
	"time"
)

// CodeLifetime is how long a minted code stays valid.
const CodeLifetime = 10 * time.Minute

// codeBytes is the code's entropy: 128 random bits.
const codeBytes = 16

// Limits on what a mint request may carry; the request comes from the Mac
// app, and these keep a malformed one from producing an unbounded page.
const (
	maxApps          = 8
	maxStepsPerApp   = 12
	maxFieldsPerApp  = 8
	maxLinksPerApp   = 4
	maxTextLen       = 512
	tokenPlaceholder = "{token}"
)

// Field is one value a follower app asks for. Value may contain
// "{token}", which the page replaces with the relay's token; the token
// never travels in a mint request.
type Field struct {
	Label string `json:"label"`
	Value string `json:"value"`
}

// Link is a button on the page: opening an app, or getting it.
type Link struct {
	Label string `json:"label"`
	URL   string `json:"url"`
}

// App is everything the page says about one follower app. The Mac app
// writes it, so the page and the Mac pane cannot disagree.
type App struct {
	Name   string   `json:"name"`
	Steps  []string `json:"steps"`
	Fields []Field  `json:"fields"`
	Links  []Link   `json:"links"`
}

// Store holds the one outstanding pairing code and the apps it shows.
// Minting replaces it, so a code from an earlier QR stops working the
// moment a newer one exists.
type Store struct {
	clock func() time.Time

	mu      sync.Mutex
	code    string
	apps    []App
	expires time.Time
}

// NewStore returns an empty store. clock may be nil, in which case time.Now
// is used.
func NewStore(clock func() time.Time) *Store {
	if clock == nil {
		clock = time.Now
	}
	return &Store{clock: clock}
}

// Mint replaces the outstanding code with a fresh one that shows apps, and
// returns the code and its expiry.
func (s *Store) Mint(apps []App) (code string, expires time.Time, err error) {
	if err := validateApps(apps); err != nil {
		return "", time.Time{}, err
	}
	raw := make([]byte, codeBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", time.Time{}, err
	}
	code = base64.RawURLEncoding.EncodeToString(raw)
	expires = s.clock().Add(CodeLifetime)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.code, s.apps, s.expires = code, apps, expires
	return code, expires, nil
}

// Lookup returns the apps the code shows, or false when code is not the
// outstanding code or has expired. The comparison is constant-time.
func (s *Store) Lookup(code string) (apps []App, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.code == "" || len(code) != len(s.code) {
		return nil, false
	}
	if subtle.ConstantTimeCompare([]byte(code), []byte(s.code)) != 1 {
		return nil, false
	}
	if !s.clock().Before(s.expires) {
		return nil, false
	}
	return s.apps, true
}

func validateApps(apps []App) error {
	if len(apps) == 0 || len(apps) > maxApps {
		return fmt.Errorf("pairing: between 1 and %d apps are required", maxApps)
	}
	text := func(v string) bool { return v != "" && len(v) <= maxTextLen }
	for _, a := range apps {
		if !text(a.Name) || len(a.Steps) > maxStepsPerApp || len(a.Fields) > maxFieldsPerApp || len(a.Links) > maxLinksPerApp {
			return errors.New("pairing: an app is empty or too large")
		}
		for _, st := range a.Steps {
			if !text(st) {
				return errors.New("pairing: a step is empty or too long")
			}
		}
		for _, f := range a.Fields {
			if !text(f.Label) || !text(f.Value) {
				return errors.New("pairing: a field is empty or too long")
			}
		}
		for _, l := range a.Links {
			u, err := url.Parse(l.URL)
			if err != nil || !text(l.Label) || len(l.URL) > maxTextLen || (u.Scheme != "https" && u.Scheme != "xdripswift") {
				return errors.New("pairing: a link must be https or xdripswift")
			}
		}
	}
	return nil
}
