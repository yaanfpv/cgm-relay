package nightscout

import "net/http"

// handleEmptyList serves the collection endpoints cgm-relay has nothing to
// report through: /api/v1/treatments.json, /api/v1/devicestatus.json, and
// /api/v1/profile. Every one of them is decoded by follower apps as a JSON
// array (see e.g. xDrip4iOS's NightscoutImportService, which decodes
// devicestatus.json and profile as arrays of optional-field documents), so
// an empty array is a valid, if uneventful, answer rather than an error.
func (h *handler) handleEmptyList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, []any{})
}
