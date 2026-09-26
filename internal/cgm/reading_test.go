package cgm

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestTrendString(t *testing.T) {
	cases := []struct {
		trend Trend
		want  string
	}{
		{TrendDoubleUp, "DoubleUp"},
		{TrendSingleUp, "SingleUp"},
		{TrendFortyFiveUp, "FortyFiveUp"},
		{TrendFlat, "Flat"},
		{TrendFortyFiveDown, "FortyFiveDown"},
		{TrendSingleDown, "SingleDown"},
		{TrendDoubleDown, "DoubleDown"},
		{TrendNotComputable, "NotComputable"},
		{TrendUnknown, "NotComputable"},
	}
	for _, c := range cases {
		if got := c.trend.String(); got != c.want {
			t.Errorf("Trend(%d).String() = %q, want %q", c.trend, got, c.want)
		}
	}
}

func TestAuthErrorMatchesIsAndAs(t *testing.T) {
	cause := errors.New("bad session")
	err := fmt.Errorf("fetch failed: %w", &AuthError{Err: cause})

	if !errors.Is(err, ErrAuth) {
		t.Error("errors.Is(err, ErrAuth) = false, want true")
	}

	var authErr *AuthError
	if !errors.As(err, &authErr) {
		t.Fatal("errors.As(err, &AuthError{}) = false, want true")
	}
	if authErr.Err != cause {
		t.Errorf("authErr.Err = %v, want %v", authErr.Err, cause)
	}

	if errors.Is(err, ErrRateLimited) {
		t.Error("errors.Is(err, ErrRateLimited) = true, want false")
	}
}

func TestRateLimitErrorMatchesIsAndAs(t *testing.T) {
	err := fmt.Errorf("fetch failed: %w", &RateLimitError{RetryAfter: 30 * time.Second})

	if !errors.Is(err, ErrRateLimited) {
		t.Error("errors.Is(err, ErrRateLimited) = false, want true")
	}

	var rlErr *RateLimitError
	if !errors.As(err, &rlErr) {
		t.Fatal("errors.As(err, &RateLimitError{}) = false, want true")
	}
	if rlErr.RetryAfter != 30*time.Second {
		t.Errorf("rlErr.RetryAfter = %v, want 30s", rlErr.RetryAfter)
	}
}

func TestTransientErrorMatchesIsAndAs(t *testing.T) {
	cause := errors.New("timeout")
	err := fmt.Errorf("fetch failed: %w", &TransientError{Err: cause})

	if !errors.Is(err, ErrTransient) {
		t.Error("errors.Is(err, ErrTransient) = false, want true")
	}
	if !errors.Is(err, cause) {
		t.Error("errors.Is(err, cause) = false, want true (Unwrap should expose it)")
	}

	var transientErr *TransientError
	if !errors.As(err, &transientErr) {
		t.Fatal("errors.As(err, &TransientError{}) = false, want true")
	}
}
