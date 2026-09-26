package librelinkup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/librelinkup/llufake"
)

func accountIDFor(userID string) string {
	sum := sha256.Sum256([]byte(userID))
	return hex.EncodeToString(sum[:])
}

// TestFetchOrdersRequestsWithRequiredHeaders checks that sign-in,
// connections and graph are requested in order with the required headers.
func TestFetchOrdersRequestsWithRequiredHeaders(t *testing.T) {
	fake := llufake.New(t)
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: "9/26/2026 3:04:05 PM",
		Timestamp:        "9/26/2026 3:04:05 PM",
		ValueInMgPerDl:   110,
		TrendArrow:       3,
	}, nil)

	src := New("user@example.com", "correct-password", WithBaseURL(fake.URL))

	current, _, err := src.Fetch(context.Background())
	if err != nil {
		t.Fatalf("Fetch() error = %v, want nil", err)
	}
	if current == nil {
		t.Fatal("Fetch() current = nil, want a reading")
	}

	reqs := fake.Requests()
	wantPaths := []string{"/llu/auth/login", "/llu/connections", "/llu/connections/fake-patient/graph"}
	if len(reqs) != len(wantPaths) {
		t.Fatalf("got %d requests, want %d: %+v", len(reqs), len(wantPaths), reqs)
	}
	for i, want := range wantPaths {
		if reqs[i].Path != want {
			t.Errorf("request %d path = %q, want %q", i, reqs[i].Path, want)
		}
	}

	for i, req := range reqs {
		if got := req.Header.Get("product"); got != productHeader {
			t.Errorf("request %d (%s) product header = %q, want %q", i, req.Path, got, productHeader)
		}
		if got := req.Header.Get("version"); got != versionHeader {
			t.Errorf("request %d (%s) version header = %q, want %q", i, req.Path, got, versionHeader)
		}
	}

	wantAccountID := accountIDFor("fake-user")
	for i, req := range reqs[1:] {
		if got := req.Header.Get("Authorization"); got != "Bearer fake-token-1" {
			t.Errorf("request %d (%s) Authorization = %q, want %q", i+1, req.Path, got, "Bearer fake-token-1")
		}
		if got := req.Header.Get("Account-Id"); got != wantAccountID {
			t.Errorf("request %d (%s) Account-Id = %q, want %q", i+1, req.Path, got, wantAccountID)
		}
	}
	if got := reqs[0].Header.Get("Authorization"); got != "" {
		t.Errorf("login request carried an Authorization header: %q", got)
	}
}

// TestFetchFollowsRegionRedirectOnce checks that a region redirect on
// sign-in is followed once and remembered for later calls.
func TestFetchFollowsRegionRedirectOnce(t *testing.T) {
	global := llufake.New(t)
	eu2 := llufake.New(t)

	global.RedirectTo("eu2")
	eu2.SetGraph(&llufake.Measurement{
		FactoryTimestamp: "9/26/2026 3:04:05 PM",
		Timestamp:        "9/26/2026 3:04:05 PM",
		ValueInMgPerDl:   110,
		TrendArrow:       3,
	}, nil)

	src := New("user@example.com", "correct-password",
		WithBaseURL(global.URL),
		WithRegionBaseURL(func(region string) string {
			if region == "eu2" {
				return eu2.URL
			}
			t.Fatalf("unexpected region redirect: %q", region)
			return ""
		}),
	)

	if _, _, err := src.Fetch(context.Background()); err != nil {
		t.Fatalf("first Fetch() error = %v, want nil", err)
	}

	if got := len(global.Requests()); got != 1 {
		t.Fatalf("global fake received %d requests after first Fetch, want 1 (the redirected login); redirect was ignored or looped: %+v", got, global.Requests())
	}
	eu2Reqs := eu2.Requests()
	wantPaths := []string{"/llu/auth/login", "/llu/connections", "/llu/connections/fake-patient/graph"}
	if len(eu2Reqs) != len(wantPaths) {
		t.Fatalf("region fake got %d requests, want %d: %+v", len(eu2Reqs), len(wantPaths), eu2Reqs)
	}
	for i, want := range wantPaths {
		if eu2Reqs[i].Path != want {
			t.Errorf("region fake request %d path = %q, want %q", i, eu2Reqs[i].Path, want)
		}
	}

	// A second Fetch reuses the cached session and region; it must not
	// redo the sign-in (let alone the redirect) at all.
	if _, _, err := src.Fetch(context.Background()); err != nil {
		t.Fatalf("second Fetch() error = %v, want nil", err)
	}
	if got := len(global.Requests()); got != 1 {
		t.Errorf("global fake received %d requests after second Fetch, want still 1 (region must be remembered)", got)
	}
}

// TestFetchRejectsMalformedRegionRedirect proves a redirect naming
// anything other than letters and digits is rejected before it
// can turn into a host name: the region resolver must never be called, so
// credentials can never be sent to whatever host a malformed region would
// have produced.
func TestFetchRejectsMalformedRegionRedirect(t *testing.T) {
	invalidRegions := []string{"evil.example/", "eu.2", "eu2/../us", "EU2.example"}

	for _, region := range invalidRegions {
		t.Run(region, func(t *testing.T) {
			fake := llufake.New(t)
			fake.RedirectTo(region)

			src := New("user@example.com", "correct-password",
				WithBaseURL(fake.URL),
				WithRegionBaseURL(func(r string) string {
					t.Fatalf("region base URL resolver was called with %q; a malformed region must never reach it", r)
					return ""
				}),
			)

			_, _, err := src.Fetch(context.Background())
			mustAuthError(t, err)

			if got := len(fake.Requests()); got != 1 {
				t.Errorf("fake received %d requests, want 1 (only the redirecting login; nothing further should be sent)", got)
			}
		})
	}
}

// TestFetchFollowsUppercaseRegionRedirect checks that a region code sent
// in uppercase is followed as its lowercase form rather than refused.
func TestFetchFollowsUppercaseRegionRedirect(t *testing.T) {
	global := llufake.New(t)
	eu2 := llufake.New(t)
	global.RedirectTo("EU2")
	eu2.SetGraph(&llufake.Measurement{FactoryTimestamp: "9/26/2026 3:04:05 PM", ValueInMgPerDl: 110, TrendArrow: 3}, nil)

	var resolved string
	src := New("user@example.com", "correct-password",
		WithBaseURL(global.URL),
		WithRegionBaseURL(func(region string) string {
			resolved = region
			return eu2.URL
		}),
	)

	if _, _, err := src.Fetch(context.Background()); err != nil {
		t.Fatalf("Fetch() error = %v, want nil", err)
	}
	if resolved != "eu2" {
		t.Errorf("region resolver got %q, want %q", resolved, "eu2")
	}
}

// TestFetchRetriesOnceAfterTokenRejected checks that an expired or
// rejected token triggers exactly one new sign-in, then the request
// succeeds.
func TestFetchRetriesOnceAfterTokenRejected(t *testing.T) {
	fake := llufake.New(t)
	fake.SetGraph(&llufake.Measurement{
		FactoryTimestamp: "9/26/2026 3:04:05 PM",
		Timestamp:        "9/26/2026 3:04:05 PM",
		ValueInMgPerDl:   110,
		TrendArrow:       3,
	}, nil)
	// The first token is good for exactly the two authenticated calls
	// (connections, graph) that the first Fetch makes.
	fake.RejectTokenAfter(2)

	src := New("user@example.com", "correct-password", WithBaseURL(fake.URL))

	if _, _, err := src.Fetch(context.Background()); err != nil {
		t.Fatalf("first Fetch() error = %v, want nil", err)
	}
	if _, _, err := src.Fetch(context.Background()); err != nil {
		t.Fatalf("second Fetch() error = %v, want nil (must recover from the rejected token with one re-login)", err)
	}

	loginCount := 0
	for _, r := range fake.Requests() {
		if r.Path == "/llu/auth/login" {
			loginCount++
		}
	}
	if loginCount != 2 {
		t.Errorf("got %d sign-ins across both fetches, want exactly 2 (the initial one plus exactly one retry)", loginCount)
	}
}

func mustAuthError(t *testing.T, err error) *cgm.AuthError {
	t.Helper()
	var authErr *cgm.AuthError
	if !errors.As(err, &authErr) {
		t.Fatalf("error = %v, want a *cgm.AuthError", err)
	}
	return authErr
}

// TestFetchReturnsTypedErrors checks that wrong credentials, rate
// limiting and transient failures each map to the right typed error and
// that wrong credentials are not retried inside Fetch.
func TestFetchReturnsTypedErrors(t *testing.T) {
	t.Run("wrong credentials", func(t *testing.T) {
		fake := llufake.New(t)
		fake.RejectCredentials()
		src := New("user@example.com", "wrong-password", WithBaseURL(fake.URL))

		_, _, err := src.Fetch(context.Background())
		mustAuthError(t, err)

		loginCount := 0
		for _, r := range fake.Requests() {
			if r.Path == "/llu/auth/login" {
				loginCount++
			}
		}
		if loginCount != 1 {
			t.Errorf("got %d sign-in attempts, want exactly 1 (rejected credentials must not be retried inside Fetch)", loginCount)
		}
	})

	t.Run("terms not accepted", func(t *testing.T) {
		fake := llufake.New(t)
		fake.RequireTermsAcceptance()
		src := New("user@example.com", "correct-password", WithBaseURL(fake.URL))

		_, _, err := src.Fetch(context.Background())
		authErr := mustAuthError(t, err)
		if !strings.Contains(authErr.Error(), "LibreLinkUp app") {
			t.Errorf("terms-not-accepted error = %q, want it to tell the user to open the LibreLinkUp app", authErr.Error())
		}
	})

	t.Run("rate limited on login", func(t *testing.T) {
		fake := llufake.New(t)
		fake.RateLimitLogin("42")
		src := New("user@example.com", "correct-password", WithBaseURL(fake.URL))

		_, _, err := src.Fetch(context.Background())
		var rlErr *cgm.RateLimitError
		if !errors.As(err, &rlErr) {
			t.Fatalf("error = %v, want a *cgm.RateLimitError", err)
		}
		if rlErr.RetryAfter != 42*time.Second {
			t.Errorf("RetryAfter = %v, want 42s", rlErr.RetryAfter)
		}
	})

	t.Run("rate limited on graph with default wait", func(t *testing.T) {
		fake := llufake.New(t)
		fake.SetGraph(&llufake.Measurement{FactoryTimestamp: "9/26/2026 3:04:05 PM", ValueInMgPerDl: 100, TrendArrow: 3}, nil)
		src := New("user@example.com", "correct-password", WithBaseURL(fake.URL))
		// First Fetch establishes the session normally.
		if _, _, err := src.Fetch(context.Background()); err != nil {
			t.Fatalf("priming Fetch() error = %v, want nil", err)
		}
		fake.RateLimit("")

		_, _, err := src.Fetch(context.Background())
		var rlErr *cgm.RateLimitError
		if !errors.As(err, &rlErr) {
			t.Fatalf("error = %v, want a *cgm.RateLimitError", err)
		}
		if rlErr.RetryAfter != defaultRateLimitWait {
			t.Errorf("RetryAfter = %v, want the default %v when the server sends no Retry-After", rlErr.RetryAfter, defaultRateLimitWait)
		}
	})

	t.Run("network failure is transient", func(t *testing.T) {
		fake := llufake.New(t)
		baseURL := fake.URL
		fake.Close()

		src := New("user@example.com", "correct-password", WithBaseURL(baseURL))
		_, _, err := src.Fetch(context.Background())
		var transientErr *cgm.TransientError
		if !errors.As(err, &transientErr) {
			t.Fatalf("error = %v, want a *cgm.TransientError", err)
		}
	})

	t.Run("server error is transient", func(t *testing.T) {
		fake := llufake.New(t)
		fake.SetGraph(&llufake.Measurement{FactoryTimestamp: "9/26/2026 3:04:05 PM", ValueInMgPerDl: 100, TrendArrow: 3}, nil)
		src := New("user@example.com", "correct-password", WithBaseURL(fake.URL))
		if _, _, err := src.Fetch(context.Background()); err != nil {
			t.Fatalf("priming Fetch() error = %v, want nil", err)
		}
		fake.Fail(500)

		_, _, err := src.Fetch(context.Background())
		var transientErr *cgm.TransientError
		if !errors.As(err, &transientErr) {
			t.Fatalf("error = %v, want a *cgm.TransientError", err)
		}
	})
}

// TestNewDefaultClientHasBoundedTimeout proves New's default client cannot
// hang forever: http.DefaultClient (the zero-value client) has Timeout ==
// 0, meaning no timeout at all, so this fails the instant that default
// were used again.
func TestNewDefaultClientHasBoundedTimeout(t *testing.T) {
	src := New("user@example.com", "correct-password")
	if src.client.Timeout <= 0 {
		t.Fatalf("default client Timeout = %v, want a positive bound", src.client.Timeout)
	}
	if src.client.Timeout != defaultRequestTimeout {
		t.Errorf("default client Timeout = %v, want defaultRequestTimeout (%v)", src.client.Timeout, defaultRequestTimeout)
	}
}

// TestFetchTimesOutOnHungRequest covers the behavioral half of the same
// requirement: a request that never gets answered still surfaces as a
// cgm.TransientError, promptly, rather than blocking Fetch forever. It
// uses WithHTTPClient with a short timeout so the test itself stays fast;
// TestNewDefaultClientHasBoundedTimeout covers that New's own default is
// bounded at all.
func TestFetchTimesOutOnHungRequest(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Never answer; return only once the client gives up (which
		// cancels the request context) or after a bound well past the
		// client's own timeout, so the deferred Close below cannot hang
		// forever waiting for this handler even if context cancellation
		// on a client-closed connection is slow to propagate.
		select {
		case <-r.Context().Done():
		case <-time.After(300 * time.Millisecond):
		}
	}))
	defer srv.Close()

	src := New("user@example.com", "correct-password",
		WithBaseURL(srv.URL),
		WithHTTPClient(&http.Client{Timeout: 50 * time.Millisecond}),
	)

	start := time.Now()
	_, _, err := src.Fetch(context.Background())
	elapsed := time.Since(start)

	var transientErr *cgm.TransientError
	if !errors.As(err, &transientErr) {
		t.Fatalf("error = %v, want a *cgm.TransientError", err)
	}
	if elapsed > 5*time.Second {
		t.Errorf("Fetch() took %v to give up on a hung request, want well under 5s", elapsed)
	}
}

// twoHistoryFixtures is a small, ordered pair of history measurements whose
// local and UTC clocks differ (IST, +5:30), shared by every case below that
// needs to prove the graph endpoint's history entries parse correctly and
// keep their order.
func twoHistoryFixtures() ([]llufake.Measurement, []cgm.Reading) {
	fixtures := []llufake.Measurement{
		{
			FactoryTimestamp: "9/26/2026 2:00:00 PM", // UTC
			Timestamp:        "9/26/2026 7:30:00 PM", // local, +5:30 ahead
			ValueInMgPerDl:   130,
			TrendArrow:       4,
		},
		{
			FactoryTimestamp: "9/26/2026 2:15:00 PM",
			Timestamp:        "9/26/2026 7:45:00 PM",
			ValueInMgPerDl:   135,
			TrendArrow:       5,
		},
	}
	want := []cgm.Reading{
		{Time: time.Date(2026, 9, 26, 14, 0, 0, 0, time.UTC), MgDl: 130, Trend: cgm.TrendFortyFiveUp, Source: sourceName},
		{Time: time.Date(2026, 9, 26, 14, 15, 0, 0, time.UTC), MgDl: 135, Trend: cgm.TrendSingleUp, Source: sourceName},
	}
	return fixtures, want
}

// TestReadingsUseFactoryTimestampAndMapTrend checks that readings parse
// with the right instant (FactoryTimestamp, never the local Timestamp),
// the trend maps to the enum, mg/dL is kept exactly, and a connection with
// no current measurement returns current == nil, for both the current
// reading and every history reading.
func TestReadingsUseFactoryTimestampAndMapTrend(t *testing.T) {
	histFixtures, wantHist := twoHistoryFixtures()

	cases := []struct {
		name        string
		current     *llufake.Measurement
		history     []llufake.Measurement
		want        *cgm.Reading
		wantHistory []cgm.Reading
	}{
		{
			name: "UTC factory time used, local timestamp ignored (IST +5:30)",
			current: &llufake.Measurement{
				FactoryTimestamp: "9/26/2026 3:04:05 PM", // UTC
				Timestamp:        "9/26/2026 8:34:05 PM", // local, +5:30 ahead
				ValueInMgPerDl:   142,
				TrendArrow:       3,
			},
			want: &cgm.Reading{
				Time:   time.Date(2026, 9, 26, 15, 4, 5, 0, time.UTC),
				MgDl:   142,
				Trend:  cgm.TrendFlat,
				Source: sourceName,
			},
		},
		{
			name: "trend arrow 1 maps to SingleDown",
			current: &llufake.Measurement{
				FactoryTimestamp: "9/26/2026 3:04:05 PM",
				Timestamp:        "9/26/2026 3:04:05 PM",
				ValueInMgPerDl:   80,
				TrendArrow:       1,
			},
			want: &cgm.Reading{Time: time.Date(2026, 9, 26, 15, 4, 5, 0, time.UTC), MgDl: 80, Trend: cgm.TrendSingleDown, Source: sourceName},
		},
		{
			name: "trend arrow 5 maps to SingleUp",
			current: &llufake.Measurement{
				FactoryTimestamp: "9/26/2026 3:04:05 PM",
				Timestamp:        "9/26/2026 3:04:05 PM",
				ValueInMgPerDl:   200,
				TrendArrow:       5,
			},
			want: &cgm.Reading{Time: time.Date(2026, 9, 26, 15, 4, 5, 0, time.UTC), MgDl: 200, Trend: cgm.TrendSingleUp, Source: sourceName},
		},
		{
			name: "unrecognized trend arrow maps to NotComputable",
			current: &llufake.Measurement{
				FactoryTimestamp: "9/26/2026 3:04:05 PM",
				Timestamp:        "9/26/2026 3:04:05 PM",
				ValueInMgPerDl:   95,
				TrendArrow:       9,
			},
			want: &cgm.Reading{Time: time.Date(2026, 9, 26, 15, 4, 5, 0, time.UTC), MgDl: 95, Trend: cgm.TrendNotComputable, Source: sourceName},
		},
		{
			name: "history readings parse with the right instant, mg/dL and trend, in order",
			current: &llufake.Measurement{
				FactoryTimestamp: "9/26/2026 3:04:05 PM",
				Timestamp:        "9/26/2026 3:04:05 PM",
				ValueInMgPerDl:   142,
				TrendArrow:       3,
			},
			history:     histFixtures,
			want:        &cgm.Reading{Time: time.Date(2026, 9, 26, 15, 4, 5, 0, time.UTC), MgDl: 142, Trend: cgm.TrendFlat, Source: sourceName},
			wantHistory: wantHist,
		},
		{
			name:        "no current measurement returns nil, history still parses",
			current:     nil,
			history:     histFixtures,
			want:        nil,
			wantHistory: wantHist,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fake := llufake.New(t)
			fake.SetGraph(c.current, c.history)
			src := New("user@example.com", "correct-password", WithBaseURL(fake.URL))

			got, gotHistory, err := src.Fetch(context.Background())
			if err != nil {
				t.Fatalf("Fetch() error = %v, want nil", err)
			}

			if c.want == nil {
				if got != nil {
					t.Errorf("current = %+v, want nil", got)
				}
			} else if got == nil {
				t.Errorf("current = nil, want %+v", c.want)
			} else {
				if !got.Time.Equal(c.want.Time) {
					t.Errorf("Time = %v, want %v", got.Time, c.want.Time)
				}
				if got.MgDl != c.want.MgDl {
					t.Errorf("MgDl = %d, want %d", got.MgDl, c.want.MgDl)
				}
				if got.Trend != c.want.Trend {
					t.Errorf("Trend = %v, want %v", got.Trend, c.want.Trend)
				}
				if got.Source != c.want.Source {
					t.Errorf("Source = %q, want %q", got.Source, c.want.Source)
				}
			}

			if len(gotHistory) != len(c.wantHistory) {
				t.Fatalf("history has %d readings, want %d: got %+v", len(gotHistory), len(c.wantHistory), gotHistory)
			}
			for i, wantR := range c.wantHistory {
				gotR := gotHistory[i]
				if !gotR.Time.Equal(wantR.Time) {
					t.Errorf("history[%d].Time = %v, want %v", i, gotR.Time, wantR.Time)
				}
				if gotR.MgDl != wantR.MgDl {
					t.Errorf("history[%d].MgDl = %d, want %d", i, gotR.MgDl, wantR.MgDl)
				}
				if gotR.Trend != wantR.Trend {
					t.Errorf("history[%d].Trend = %v, want %v", i, gotR.Trend, wantR.Trend)
				}
				if gotR.Source != wantR.Source {
					t.Errorf("history[%d].Source = %q, want %q", i, gotR.Source, wantR.Source)
				}
			}
		})
	}
}

// TestErrorsNeverExposeCredentialsOrToken checks that the password and
// token never appear in any error message.
func TestErrorsNeverExposeCredentialsOrToken(t *testing.T) {
	const password = "S3cr3t-Marker-Pw"
	var errs []error

	// Wrong credentials.
	fakeBadCreds := llufake.New(t)
	fakeBadCreds.RejectCredentials()
	srcBadCreds := New("user@example.com", password, WithBaseURL(fakeBadCreds.URL))
	_, _, err := srcBadCreds.Fetch(context.Background())
	if err == nil {
		t.Fatal("wrong-credentials Fetch() error = nil, want an error")
	}
	errs = append(errs, err)

	// Terms not accepted.
	fakeTerms := llufake.New(t)
	fakeTerms.RequireTermsAcceptance()
	srcTerms := New("user@example.com", password, WithBaseURL(fakeTerms.URL))
	_, _, err = srcTerms.Fetch(context.Background())
	if err == nil {
		t.Fatal("terms Fetch() error = nil, want an error")
	}
	errs = append(errs, err)

	// Token rejected immediately after being issued, exercising the path
	// that reports a freshly signed-in session being turned away.
	fakeToken := llufake.New(t)
	fakeToken.SetGraph(&llufake.Measurement{FactoryTimestamp: "9/26/2026 3:04:05 PM", ValueInMgPerDl: 100, TrendArrow: 3}, nil)
	fakeToken.RejectTokenAfter(0)
	srcToken := New("user@example.com", password, WithBaseURL(fakeToken.URL))
	_, _, err = srcToken.Fetch(context.Background())
	if err == nil {
		t.Fatal("exhausted-token Fetch() error = nil, want an error")
	}
	errs = append(errs, err)
	knownTokens := []string{"fake-token-1", "fake-token-2"}

	// Server error.
	fakeFail := llufake.New(t)
	fakeFail.SetGraph(&llufake.Measurement{FactoryTimestamp: "9/26/2026 3:04:05 PM", ValueInMgPerDl: 100, TrendArrow: 3}, nil)
	srcFail := New("user@example.com", password, WithBaseURL(fakeFail.URL))
	if _, _, err := srcFail.Fetch(context.Background()); err != nil {
		t.Fatalf("priming Fetch() error = %v, want nil", err)
	}
	fakeFail.Fail(500)
	_, _, err = srcFail.Fetch(context.Background())
	if err == nil {
		t.Fatal("server-error Fetch() error = nil, want an error")
	}
	errs = append(errs, err)

	for _, e := range errs {
		msg := e.Error()
		if strings.Contains(msg, password) {
			t.Errorf("error %q contains the account password", msg)
		}
		for _, tok := range knownTokens {
			if strings.Contains(msg, tok) {
				t.Errorf("error %q contains a session token (%s)", msg, tok)
			}
		}
	}
}
