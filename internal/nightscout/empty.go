package nightscout

import (
	"net/http"
	"slices"
	"strings"
)

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

// propertiesPrefix is the path a follower app asks Nightscout's v2
// properties by, with the wanted names as the one segment after it.
const propertiesPrefix = "/api/v2/properties"

// modelledProperties are the property names the relay answers. Each is
// always the empty object: the relay has no insulin or carbs on board and
// never invents a value, which is Nightscout's own answer when it has none.
var modelledProperties = []string{"iob", "cob"}

// handleProperties serves /api/v2/properties and /api/v2/properties/<names>.
// The names are the first non-empty segment after the prefix, split on
// commas with empty items dropped; an empty selection means every modelled
// name. A name the relay does not model is dropped and a repeated name
// appears once.
func (h *handler) handleProperties(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, propertiesPrefix)
	segment := ""
	for _, s := range strings.Split(rest, "/") {
		if s != "" {
			segment = s
			break
		}
	}
	var wanted []string
	for _, name := range strings.Split(segment, ",") {
		if name != "" {
			wanted = append(wanted, name)
		}
	}
	if len(wanted) == 0 {
		wanted = modelledProperties
	}
	out := map[string]struct{}{}
	for _, name := range wanted {
		if slices.Contains(modelledProperties, name) {
			out[name] = struct{}{}
		}
	}
	writeJSON(w, r, out)
}
