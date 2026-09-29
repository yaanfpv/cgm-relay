package nightscout

import "net/http"

// handleEmptyList serves the collection endpoints cgm-relay has nothing to
// report through: treatments, devicestatus and profile, each under the
// spellings follower apps request it by (see registerRoutes). Every one of
// them is decoded by follower apps as a JSON array (see e.g. xDrip4iOS's
// NightscoutImportService, which decodes devicestatus.json and profile as
// arrays of optional-field documents), so an empty array is a valid, if
// uneventful, answer rather than an error.
func (h *handler) handleEmptyList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, []any{})
}
