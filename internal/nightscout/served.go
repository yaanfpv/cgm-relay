package nightscout

import (
	"context"
	"net/http"
	"sync/atomic"
)

// servedKey is the request context key under which ObserveReadings stores
// its flag.
type servedKey struct{}

// ObserveReadings returns r carrying a flag, and a function reporting
// whether the handler, once it has served that request, answered it with at
// least one reading. A handler only gets that far for a request that passed
// the credential check, so a caller wrapping the handler can tell a client
// that was actually given glucose data from one that was refused or was
// answered with an empty list.
func ObserveReadings(r *http.Request) (*http.Request, func() bool) {
	served := new(atomic.Bool)
	return r.WithContext(context.WithValue(r.Context(), servedKey{}, served)), served.Load
}

// noteReadings marks r as answered with count readings. It does nothing for
// a request that nobody is observing, or for a response with no readings.
func noteReadings(r *http.Request, count int) {
	if count == 0 {
		return
	}
	if served, ok := r.Context().Value(servedKey{}).(*atomic.Bool); ok {
		served.Store(true)
	}
}
