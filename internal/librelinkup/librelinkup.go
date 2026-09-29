// Package librelinkup implements cgm.Source against LibreLinkUp, the cloud
// account the official LibreLinkUp follower app reads from.
//
// LibreLinkUp has no public API contract; the request shape, headers and
// response fields here are taken from two public sources: xDrip4iOS
// (https://github.com/JohanDegraeve/xdripswift), an open-source LibreLinkUp
// follower, and the community description at
// https://gist.github.com/khskekec/6c13ba01b10d3018d816706a32ae8ab2.
package librelinkup

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

const (
	// sourceName is the value stored in every cgm.Reading.Source this
	// package produces.
	sourceName = "librelinkup"

	// productHeader and versionHeader are the values xDrip4iOS's iOS
	// LibreLinkUp follower sends (xDrip/Constants/ConstantsLibreLinkUp.swift
	// in xDrip4iOS, https://github.com/JohanDegraeve/xdripswift: product
	// "llu.ios", libreLinkUpVersionDefault "4.17.0"). LibreLinkUp answers
	// with an unrelated response shape to a stale version header.
	productHeader = "llu.ios"
	versionHeader = "4.17.0"

	// defaultBaseURL is the generic LibreLinkUp host; a sign-in against it
	// answers with a region redirect when the account belongs to a
	// specific region (LibreLinkUpFollowManager.swift's checkLoginAndConnections).
	defaultBaseURL = "https://api.libreview.io"

	// defaultRateLimitWait is used when a 429 response carries no
	// Retry-After header.
	defaultRateLimitWait = 60 * time.Second

	// defaultRequestTimeout bounds the default client's round trip.
	// LibreLinkUp answers in well under a second in ordinary operation;
	// 30s is generous for a slow response while still being far short of
	// the poller's own once-a-minute cycle, so a hung request cannot
	// silently stall reading collection until the next process restart.
	defaultRequestTimeout = 30 * time.Second

	// maxRegionRedirects bounds the sign-in redirect loop so a
	// misconfigured or looping server cannot hang a Fetch call forever.
	maxRegionRedirects = 5

	// LibreLinkUp's own status codes on a POST /llu/auth/login response
	// body (RequestLoginResponse.status in
	// LibreLinkUpFollowManager.swift's checkLoginAndConnections): 0 is
	// success, 2 means the credentials were rejected, and 4 means the
	// account must accept LibreLinkUp's updated terms before signing in
	// again.
	loginStatusInvalidCredentials = 2
	loginStatusTermsNotAccepted   = 4
)

// errTokenRejected is returned internally by doAuthenticated when
// LibreLinkUp answers an authenticated request with HTTP 401. Fetch treats
// it as a signal to sign in again exactly once, never as the error it
// returns to its own caller.
var errTokenRejected = errors.New("librelinkup: token rejected")

// Sentinels a caller can match with errors.Is, including through a
// *cgm.AuthError's Unwrap: authenticate wraps ErrInvalidCredentials and
// ErrTermsNotAccepted inside one so Fetch's own errors.Is(err, cgm.ErrAuth)
// classification (poller.handleFetchError) keeps working unchanged, while
// a caller that needs the finer distinction -- CheckAccount's own caller,
// cmd/cgm-relay's check-account command -- can still match the exact
// cause. ErrNoConnections is never wrapped in a cgm.AuthError: signing in
// succeeded, so it is not an authentication failure.
var (
	ErrInvalidCredentials = errors.New("librelinkup: email or password was rejected")
	ErrTermsNotAccepted   = errors.New("librelinkup: LibreLinkUp needs you to accept its updated terms; open the LibreLinkUp app, sign in, and accept the prompt, then try again")
	ErrNoConnections      = errors.New("librelinkup: account has no LibreLinkUp connections shared with it")
)

// Source fetches glucose readings from a LibreLinkUp follower account. The
// zero value is not usable; construct one with New.
//
// An account can share more than one patient's data with a follower.
// Source has no way to choose among them beyond LibreLinkUp's own order, so
// it follows the first connection returned by the account's connections
// list and ignores the rest.
type Source struct {
	email    string
	password string
	client   *http.Client

	regionBaseURL func(region string) string

	mu        sync.Mutex
	baseURL   string
	token     string
	accountID string // lowercase hex SHA-256 of the signed-in user id
	patientID string
}

// Option configures a Source constructed by New.
type Option func(*Source)

// WithBaseURL points the Source at a base URL other than LibreLinkUp's own
// generic host. Tests use it to target a fake server.
func WithBaseURL(baseURL string) Option {
	return func(s *Source) { s.baseURL = strings.TrimRight(baseURL, "/") }
}

// WithHTTPClient overrides the http.Client used for every request. The
// default client already carries defaultRequestTimeout; an override that
// carries no timeout of its own can let a hung request block Fetch
// forever.
func WithHTTPClient(c *http.Client) Option {
	return func(s *Source) { s.client = c }
}

// WithRegionBaseURL overrides how a region name from a sign-in redirect
// (e.g. "eu2") becomes a base URL. Tests use it to point a redirect at a
// second fake server instead of a real regional LibreLinkUp host.
func WithRegionBaseURL(fn func(region string) string) Option {
	return func(s *Source) { s.regionBaseURL = fn }
}

// New returns a Source that signs in to LibreLinkUp as email and password.
func New(email, password string, opts ...Option) *Source {
	s := &Source{
		email:         email,
		password:      password,
		client:        &http.Client{Timeout: defaultRequestTimeout},
		baseURL:       defaultBaseURL,
		regionBaseURL: defaultRegionBaseURL,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func defaultRegionBaseURL(region string) string {
	return "https://api-" + region + ".libreview.io"
}

// isValidRegionCode reports whether region is safe to place into a host
// name: every real LibreLinkUp region code (us, eu, eu2, ae, ...) is
// lowercase letters and digits only, so anything else is treated as a
// malformed sign-in response rather than followed.
func isValidRegionCode(region string) bool {
	if region == "" {
		return false
	}
	for _, r := range region {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') {
			return false
		}
	}
	return true
}

// Fetch implements cgm.Source.
func (s *Source) Fetch(ctx context.Context) (*cgm.Reading, []cgm.Reading, error) {
	token, accountID, patientID, ok := s.cachedSession()
	if !ok {
		var err error
		token, accountID, patientID, err = s.login(ctx)
		if err != nil {
			return nil, nil, err
		}
	}

	graph, err := s.fetchGraph(ctx, token, accountID, patientID)
	if errors.Is(err, errTokenRejected) {
		token, accountID, patientID, err = s.login(ctx)
		if err != nil {
			return nil, nil, err
		}
		graph, err = s.fetchGraph(ctx, token, accountID, patientID)
		if errors.Is(err, errTokenRejected) {
			err = &cgm.AuthError{Err: errors.New("librelinkup: LibreLinkUp rejected the new session immediately; check the account credentials")}
		}
	}
	if err != nil {
		return nil, nil, err
	}
	return parseGraph(graph)
}

// login signs in, resolves the first followed connection, and caches the
// result for later Fetch calls. errTokenRejected never escapes login: it
// only means anything to Fetch's own retry-once check around an already
// cached session, so a freshly issued token that is rejected immediately
// is reported as an AuthError instead.
func (s *Source) login(ctx context.Context) (token, accountID, patientID string, err error) {
	token, accountID, err = s.authenticate(ctx)
	if err != nil {
		return "", "", "", err
	}
	patientID, err = s.firstConnection(ctx, token, accountID)
	if err != nil {
		if errors.Is(err, errTokenRejected) {
			return "", "", "", &cgm.AuthError{Err: errors.New("librelinkup: LibreLinkUp rejected a newly issued session immediately")}
		}
		return "", "", "", err
	}
	s.storeSession(token, accountID, patientID)
	return token, accountID, patientID, nil
}

// authenticate signs in, following at most maxRegionRedirects region
// redirects, and returns the bearer token and the Account-Id header value
// for the signed-in user.
func (s *Source) authenticate(ctx context.Context) (token, accountID string, err error) {
	baseURL := s.currentBaseURL()

	for attempt := 0; attempt < maxRegionRedirects; attempt++ {
		resp, err := s.postLogin(ctx, baseURL)
		if err != nil {
			return "", "", err
		}

		switch resp.Status {
		case loginStatusInvalidCredentials:
			return "", "", &cgm.AuthError{Err: ErrInvalidCredentials}
		case loginStatusTermsNotAccepted:
			return "", "", &cgm.AuthError{Err: ErrTermsNotAccepted}
		}

		if resp.Data.Redirect && resp.Data.Region != "" {
			// Region codes are case-insensitive (xDrip4iOS lowercases them before matching).
			region := strings.ToLower(resp.Data.Region)
			if !isValidRegionCode(region) {
				return "", "", &cgm.AuthError{Err: fmt.Errorf("librelinkup: sign-in redirect named an invalid region")}
			}
			baseURL = s.regionBaseURL(region)
			continue
		}

		if resp.Data.User == nil || resp.Data.AuthTicket == nil || resp.Data.User.ID == "" || resp.Data.AuthTicket.Token == "" {
			return "", "", fmt.Errorf("librelinkup: sign-in response carried no user id or token")
		}

		s.setBaseURL(baseURL)
		return resp.Data.AuthTicket.Token, sha256Hex(resp.Data.User.ID), nil
	}

	return "", "", &cgm.TransientError{Err: errors.New("librelinkup: too many region redirects while signing in")}
}

// postLogin sends the sign-in request to baseURL and decodes its body. It
// never includes the request body or response body in an error, since both
// can carry the account password.
func (s *Source) postLogin(ctx context.Context, baseURL string) (*loginResponse, error) {
	body, err := json.Marshal(loginRequest{Email: s.email, Password: s.password})
	if err != nil {
		return nil, fmt.Errorf("librelinkup: encode sign-in request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/llu/auth/login", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("librelinkup: build sign-in request: %w", err)
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("product", productHeader)
	req.Header.Set("version", versionHeader)

	resp, data, err := s.send(req)
	if err != nil {
		return nil, err
	}

	switch resp.StatusCode {
	case http.StatusOK:
		var out loginResponse
		if err := json.Unmarshal(data, &out); err != nil {
			return nil, fmt.Errorf("librelinkup: decode sign-in response: %w", err)
		}
		return &out, nil
	case http.StatusTooManyRequests:
		return nil, rateLimitError(resp)
	default:
		return nil, &cgm.TransientError{Err: fmt.Errorf("librelinkup: unexpected status %d signing in", resp.StatusCode)}
	}
}

// firstConnection resolves the patient ID of the account's first
// connection, the one this Source follows.
func (s *Source) firstConnection(ctx context.Context, token, accountID string) (string, error) {
	body, err := s.doAuthenticated(ctx, http.MethodGet, "/llu/connections", token, accountID)
	if err != nil {
		return "", err
	}

	var out connectionsResponse
	if err := json.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("librelinkup: decode connections response: %w", err)
	}
	if len(out.Data) == 0 {
		return "", ErrNoConnections
	}
	return out.Data[0].PatientID, nil
}

// CheckAccount signs in with the credentials this Source was constructed
// with and confirms the account follows at least one connection, without
// fetching a reading. It exists for a caller that wants to validate an
// account before saving its credentials -- cmd/cgm-relay's check-account
// command -- distinct from Fetch's own sign-in-on-demand path: unlike
// Fetch, this never caches the session it establishes, since a caller
// checking an account has no further use for it.
func (s *Source) CheckAccount(ctx context.Context) error {
	token, accountID, err := s.authenticate(ctx)
	if err != nil {
		return err
	}
	_, err = s.firstConnection(ctx, token, accountID)
	if errors.Is(err, errTokenRejected) {
		return &cgm.AuthError{Err: errors.New("librelinkup: LibreLinkUp rejected a newly issued session immediately")}
	}
	return err
}

// fetchGraph fetches the current measurement and history for patientID.
func (s *Source) fetchGraph(ctx context.Context, token, accountID, patientID string) (*graphResponse, error) {
	body, err := s.doAuthenticated(ctx, http.MethodGet, "/llu/connections/"+patientID+"/graph", token, accountID)
	if err != nil {
		return nil, err
	}

	var out graphResponse
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("librelinkup: decode graph response: %w", err)
	}
	return &out, nil
}

// doAuthenticated sends a bearer-authenticated GET and returns its body on
// HTTP 200. It never includes the token in an error.
func (s *Source) doAuthenticated(ctx context.Context, method, path, token, accountID string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, s.currentBaseURL()+path, nil)
	if err != nil {
		return nil, fmt.Errorf("librelinkup: build request: %w", err)
	}
	req.Header.Set("product", productHeader)
	req.Header.Set("version", versionHeader)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Account-Id", accountID)

	resp, body, err := s.send(req)
	if err != nil {
		return nil, err
	}

	switch resp.StatusCode {
	case http.StatusOK:
		return body, nil
	case http.StatusUnauthorized:
		return nil, errTokenRejected
	case http.StatusTooManyRequests:
		return nil, rateLimitError(resp)
	default:
		return nil, &cgm.TransientError{Err: fmt.Errorf("librelinkup: unexpected status %d from %s %s", resp.StatusCode, method, path)}
	}
}

// send performs the HTTP round trip, turning any network-level failure
// into a cgm.TransientError. The message it builds names only the method
// and path, never headers or bodies, so it cannot echo a password or
// token.
func (s *Source) send(req *http.Request) (*http.Response, []byte, error) {
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, nil, &cgm.TransientError{Err: fmt.Errorf("librelinkup: %s %s: %w", req.Method, req.URL.Path, err)}
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, &cgm.TransientError{Err: fmt.Errorf("librelinkup: read response body: %w", err)}
	}
	return resp, body, nil
}

// rateLimitError builds a cgm.RateLimitError from a 429 response, using
// Retry-After when present and a fixed default otherwise.
func rateLimitError(resp *http.Response) error {
	wait := defaultRateLimitWait
	if v := resp.Header.Get("Retry-After"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs >= 0 {
			wait = time.Duration(secs) * time.Second
		}
	}
	return &cgm.RateLimitError{RetryAfter: wait}
}

func sha256Hex(userID string) string {
	sum := sha256.Sum256([]byte(userID))
	return hex.EncodeToString(sum[:])
}

// cachedSession returns the previously stored token, account ID and
// patient ID, and whether they are usable.
func (s *Source) cachedSession() (token, accountID, patientID string, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.token, s.accountID, s.patientID, s.token != "" && s.patientID != ""
}

func (s *Source) storeSession(token, accountID, patientID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.token, s.accountID, s.patientID = token, accountID, patientID
}

func (s *Source) currentBaseURL() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.baseURL
}

func (s *Source) setBaseURL(baseURL string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.baseURL = baseURL
}

// loginRequest is the POST /llu/auth/login body
// (LibreLinkUpFollowManager.swift's requestLogin).
type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

// loginResponse is the POST /llu/auth/login response body
// (LibreLinkUpModels.swift's RequestLoginResponse, wrapped in the generic
// Response<T> envelope). Redirect and Region are only populated when the
// account belongs to a different region than baseURL.
type loginResponse struct {
	Status int `json:"status"`
	Data   struct {
		User *struct {
			ID string `json:"id"`
		} `json:"user"`
		AuthTicket *struct {
			Token string `json:"token"`
		} `json:"authTicket"`
		Redirect bool   `json:"redirect"`
		Region   string `json:"region"`
	} `json:"data"`
}

// connectionsResponse is the GET /llu/connections response body
// (LibreLinkUpModels.swift's RequestConnectionsResponse, as a list).
type connectionsResponse struct {
	Status int `json:"status"`
	Data   []struct {
		PatientID string `json:"patientId"`
	} `json:"data"`
}

// graphResponse is the GET /llu/connections/{patientId}/graph response body
// (LibreLinkUpModels.swift's RequestGraphResponse).
type graphResponse struct {
	Status int `json:"status"`
	Data   struct {
		Connection *struct {
			GlucoseMeasurement *glucoseMeasurement `json:"glucoseMeasurement"`
		} `json:"connection"`
		GraphData []glucoseMeasurement `json:"graphData"`
	} `json:"data"`
}

// glucoseMeasurement is one entry from graphData or connection.glucoseMeasurement
// (LibreLinkUpModels.swift's RequestGraphResponseGlucoseMeasurement).
// FactoryTimestamp is the sensor's own UTC clock; Timestamp (not modeled
// here) is the reporting phone's local clock and is never a reliable
// instant, so this Source never reads it.
type glucoseMeasurement struct {
	FactoryTimestamp string  `json:"FactoryTimestamp"`
	ValueInMgPerDl   float64 `json:"ValueInMgPerDl"`
	TrendArrow       int     `json:"TrendArrow"`
}

// factoryTimestampLayout parses LibreLinkUp's FactoryTimestamp strings
// (e.g. "2/13/2020 5:29:23 PM"), which carry no time zone of their own but
// are documented to already be UTC
// (LibreLinkUpFollowManager.swift's dateFormatter, fixed to the "UTC"
// TimeZone before decoding this exact field).
const factoryTimestampLayout = "1/2/2006 3:04:05 PM"

func parseFactoryTimestamp(v string) (time.Time, error) {
	t, err := time.ParseInLocation(factoryTimestampLayout, v, time.UTC)
	if err != nil {
		return time.Time{}, fmt.Errorf("librelinkup: parse FactoryTimestamp %q: %w", v, err)
	}
	return t, nil
}

// toReading converts m into the shared Reading shape.
func (m glucoseMeasurement) toReading() (cgm.Reading, error) {
	t, err := parseFactoryTimestamp(m.FactoryTimestamp)
	if err != nil {
		return cgm.Reading{}, err
	}
	return cgm.Reading{
		Time:   t,
		MgDl:   int(math.Round(m.ValueInMgPerDl)),
		Trend:  mapTrend(m.TrendArrow),
		Source: sourceName,
	}, nil
}

// mapTrend converts LibreLinkUp's TrendArrow field to the shared Trend
// enum. The mapping (1 SingleDown, 2 FortyFiveDown, 3 Flat, 4 FortyFiveUp,
// 5 SingleUp, anything else NotComputable) is not in Abbott's own
// documentation; it is taken from the widely used
// github.com/timoschlueter/nightscout-librelink-up uploader's
// src/helpers/helpers.ts mapTrendArrow function.
func mapTrend(v int) cgm.Trend {
	switch v {
	case 1:
		return cgm.TrendSingleDown
	case 2:
		return cgm.TrendFortyFiveDown
	case 3:
		return cgm.TrendFlat
	case 4:
		return cgm.TrendFortyFiveUp
	case 5:
		return cgm.TrendSingleUp
	default:
		return cgm.TrendNotComputable
	}
}

// parseGraph converts a graph response into the current reading (nil when
// the account has none right now) and the history readings it carried.
func parseGraph(resp *graphResponse) (*cgm.Reading, []cgm.Reading, error) {
	var current *cgm.Reading
	if resp.Data.Connection != nil && resp.Data.Connection.GlucoseMeasurement != nil {
		r, err := resp.Data.Connection.GlucoseMeasurement.toReading()
		if err != nil {
			return nil, nil, err
		}
		current = &r
	}

	history := make([]cgm.Reading, 0, len(resp.Data.GraphData))
	for _, m := range resp.Data.GraphData {
		r, err := m.toReading()
		if err != nil {
			return nil, nil, err
		}
		history = append(history, r)
	}

	return current, history, nil
}
