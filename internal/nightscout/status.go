package nightscout

import "net/http"

// statusPayload is the shape of /api/v1/status.json. Follower apps such as
// xDrip4iOS decode only "status" (its NightscoutStatusPayload type), so
// that field is the load-bearing one; Settings is required by Nightguard
// (see statusSettings), and the rest matches the fields real Nightscout
// sites also report.
type statusPayload struct {
	Status          string         `json:"status"`
	APIEnabled      bool           `json:"apiEnabled"`
	ServerTime      string         `json:"serverTime"`
	ServerTimeEpoch int64          `json:"serverTimeEpoch"`
	Settings        statusSettings `json:"settings"`
}

// statusSettings carries the site's display unit. Nightguard's own
// NightscoutService.swift (units(from:), called from readStatus and, in
// turn, from views/PrefsView.swift's add-a-site flow) requires a
// "settings" object with a "units" string and refuses the site outright
// if either is absent. cgm-relay always reports readings in mg/dL, so
// Units is always that one value.
type statusSettings struct {
	Units string `json:"units"`
}

// handleStatus serves /api/v1/status.json.
func (h *handler) handleStatus(w http.ResponseWriter, r *http.Request) {
	now := h.clock().UTC()
	writeJSON(w, r, statusPayload{
		Status:          "ok",
		APIEnabled:      true,
		ServerTime:      now.Format("2006-01-02T15:04:05.000Z"),
		ServerTimeEpoch: now.UnixMilli(),
		Settings:        statusSettings{Units: "mg/dl"},
	})
}

// handleAuthTest serves /api/v1/experiments/test, which follower apps such
// as xDrip4iOS use only to confirm a credential is accepted: they discard
// the body and treat any non-error response as success.
func (h *handler) handleAuthTest(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, map[string]string{"status": "ok"})
}
