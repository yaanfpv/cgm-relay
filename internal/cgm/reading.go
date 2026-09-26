// Package cgm defines the glucose reading model shared by every CGM source,
// store, and API surface in cgm-relay.
package cgm

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// Trend is the rate-of-change direction reported alongside a glucose value,
// using the same vocabulary as Nightscout's own direction field.
type Trend int

// The trend values a Source can report. TrendUnknown is the zero value, for
// a reading whose device did not compute a trend.
const (
	TrendUnknown Trend = iota
	TrendDoubleUp
	TrendSingleUp
	TrendFortyFiveUp
	TrendFlat
	TrendFortyFiveDown
	TrendSingleDown
	TrendDoubleDown
	TrendNotComputable
)

// String returns the Nightscout direction name for t, or "NotComputable" for
// any value outside the known set (which covers TrendUnknown too, since
// Nightscout has no separate name for "no trend").
func (t Trend) String() string {
	switch t {
	case TrendDoubleUp:
		return "DoubleUp"
	case TrendSingleUp:
		return "SingleUp"
	case TrendFortyFiveUp:
		return "FortyFiveUp"
	case TrendFlat:
		return "Flat"
	case TrendFortyFiveDown:
		return "FortyFiveDown"
	case TrendSingleDown:
		return "SingleDown"
	case TrendDoubleDown:
		return "DoubleDown"
	default:
		return "NotComputable"
	}
}

// Reading is one glucose measurement from a CGM cloud account.
type Reading struct {
	// Time is when the reading was taken, always in UTC.
	Time time.Time
	// MgDl is the glucose value in mg/dL.
	MgDl int
	// Trend is the reported rate-of-change direction.
	Trend Trend
	// Source names where the reading came from, e.g. "librelinkup".
	Source string
}

// Source fetches glucose readings from a CGM cloud account.
type Source interface {
	// Fetch returns the account's current reading, or nil if the account
	// has none right now (a warming-up sensor, an ended session, or no
	// data currently shared), plus any additional history readings the
	// account exposes in the same call. It returns an error satisfying
	// errors.As against AuthError, RateLimitError, or TransientError when
	// the underlying request fails in one of those ways.
	Fetch(ctx context.Context) (current *Reading, history []Reading, err error)
}

// Sentinels a caller can match with errors.Is against any of the typed
// errors below, without needing the concrete type.
var (
	// ErrAuth is the sentinel behind every AuthError.
	ErrAuth = errors.New("cgm: authentication failed")
	// ErrRateLimited is the sentinel behind every RateLimitError.
	ErrRateLimited = errors.New("cgm: rate limited")
	// ErrTransient is the sentinel behind every TransientError.
	ErrTransient = errors.New("cgm: transient failure")
)

// AuthError reports that a Source rejected the configured credentials.
type AuthError struct {
	// Err is the underlying cause, if the source gave one.
	Err error
}

func (e *AuthError) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("%s: %v", ErrAuth, e.Err)
	}
	return ErrAuth.Error()
}

// Unwrap exposes the underlying cause, if any, so errors.Is/As can also
// match against it.
func (e *AuthError) Unwrap() error { return e.Err }

// Is reports whether target is the ErrAuth sentinel, so callers can test
// with errors.Is(err, cgm.ErrAuth) as well as errors.As(err, &cgm.AuthError{}).
func (e *AuthError) Is(target error) bool { return target == ErrAuth }

// RateLimitError reports that a Source is throttling requests.
type RateLimitError struct {
	// RetryAfter is how long the source asked the caller to wait.
	RetryAfter time.Duration
}

func (e *RateLimitError) Error() string {
	return fmt.Sprintf("%s: retry after %s", ErrRateLimited, e.RetryAfter)
}

// Is reports whether target is the ErrRateLimited sentinel.
func (e *RateLimitError) Is(target error) bool { return target == ErrRateLimited }

// TransientError reports a failure worth retrying, such as a network
// timeout or a 5xx response.
type TransientError struct {
	// Err is the underlying cause.
	Err error
}

func (e *TransientError) Error() string {
	return fmt.Sprintf("%s: %v", ErrTransient, e.Err)
}

// Unwrap exposes the underlying cause so errors.Is/As can also match
// against it.
func (e *TransientError) Unwrap() error { return e.Err }

// Is reports whether target is the ErrTransient sentinel.
func (e *TransientError) Is(target error) bool { return target == ErrTransient }
