// Package nightscout serves stored glucose readings through the subset of
// Nightscout's REST API that follower apps such as xDrip4iOS, xDrip+,
// LoopFollow and Nightguard use to poll a site.
package nightscout

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// ReadingRange is the narrow slice of *store.Store the Nightscout API needs:
// a time-bounded, newest-first read of stored readings. Defined here rather
// than depended on directly so this package never needs a real database to
// be tested.
type ReadingRange interface {
	Range(ctx context.Context, q store.RangeQuery) ([]cgm.Reading, error)
}

// Clock returns the current time. Handlers that report a server time (such
// as status.json) call it instead of time.Now directly, so a test can pin
// the clock instead of racing the wall clock.
type Clock func() time.Time

// handler implements the Nightscout API surface over a ReadingRange.
type handler struct {
	readings     ReadingRange
	token        string
	tokenSHA1Hex string
	clock        Clock
	mux          *http.ServeMux
}

// New builds the Nightscout API handler. token authenticates every request
// (see checkAuth) and must not be empty: a handler with no token would
// serve readings to anyone who could reach it. clock may be nil, in which
// case time.Now is used.
func New(readings ReadingRange, token string, clock Clock) (http.Handler, error) {
	if readings == nil {
		return nil, errors.New("nightscout: readings must not be nil")
	}
	if token == "" {
		return nil, errors.New("nightscout: token must not be empty")
	}
	if clock == nil {
		clock = time.Now
	}

	h := &handler{
		readings:     readings,
		token:        token,
		tokenSHA1Hex: sha1Hex(token),
		clock:        clock,
	}
	h.mux = http.NewServeMux()
	h.registerRoutes()
	return h, nil
}

// registerRoutes wires every supported Nightscout endpoint to its handler.
func (h *handler) registerRoutes() {
	h.mux.HandleFunc("GET /api/v1/entries/sgv.json", h.handleEntries)
	h.mux.HandleFunc("GET /api/v1/entries.json", h.handleEntries)
	h.mux.HandleFunc("GET /api/v1/entries/current.json", h.handleCurrent)
	h.mux.HandleFunc("GET /api/v1/status.json", h.handleStatus)
	h.mux.HandleFunc("GET /api/v1/experiments/test", h.handleAuthTest)
	h.mux.HandleFunc("GET /api/v1/treatments.json", h.handleEmptyList)
	h.mux.HandleFunc("GET /api/v1/devicestatus.json", h.handleEmptyList)
	h.mux.HandleFunc("GET /api/v1/profile", h.handleEmptyList)
}

// ServeHTTP authenticates the request, then dispatches it to the matching
// Nightscout endpoint. Every endpoint requires a valid credential; a
// request that fails checkAuth never reaches routing at all.
func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !h.checkAuth(r) {
		http.Error(w, "nightscout: missing or invalid credential", http.StatusUnauthorized)
		return
	}
	h.mux.ServeHTTP(w, r)
}
