package nightscout_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/nightscout"
)

// xdripStatusPayload mirrors xDrip4iOS's own NightscoutStatusPayload
// (FollowerServiceStatusMonitor.swift): it decodes only "status" out of
// status.json, so that is the field this test depends on.
type xdripStatusPayload struct {
	Status string `json:"status"`
}

// TestStatusJSON checks that status.json decodes under the same field
// xDrip4iOS reads, and reports the server time from the handler's clock
// rather than the real wall clock, so serverTimeEpoch is checkable
// exactly.
func TestStatusJSON(t *testing.T) {
	now := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	h, err := nightscout.New(&fakeStore{}, testToken, fixedClock(now))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	rec := doRequest(t, h, "/api/v1/status.json", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	var status xdripStatusPayload
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode as xDrip4iOS's own status payload: %v", err)
	}
	if status.Status == "" {
		t.Error(`status.json's "status" field is empty, want a non-empty indicator`)
	}

	var full struct {
		ServerTimeEpoch int64 `json:"serverTimeEpoch"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &full); err != nil {
		t.Fatalf("decode serverTimeEpoch: %v", err)
	}
	if want := now.UnixMilli(); full.ServerTimeEpoch != want {
		t.Errorf("serverTimeEpoch = %d, want %d (the handler's clock, not the wall clock)", full.ServerTimeEpoch, want)
	}
}

// nightguardStatusPayload mirrors the shape nightscout/nightguard's own
// NightscoutService.swift decodes out of status.json (its private
// units(from:) method, called from readStatus, which is in turn called
// from views/PrefsView.swift when a person adds this relay as a site):
// it requires a "settings" object carrying a non-empty "units" string,
// and refuses the site outright (readLegacyStatus's guard, surfaced to
// PrefsView as completion(error)) if either is missing.
type nightguardStatusPayload struct {
	Settings struct {
		Units string `json:"units"`
	} `json:"settings"`
}

// TestStatusJSONCarriesNightguardUnits checks that status.json carries
// "settings.units" naming mg/dl, since nightguard's
// NightscoutService.units(from:) treats a missing or empty value as
// "Nightscout did not return configured glucose units." and rejects the
// site in views/PrefsView.swift's add-a-site flow.
func TestStatusJSONCarriesNightguardUnits(t *testing.T) {
	h, err := nightscout.New(&fakeStore{}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	rec := doRequest(t, h, "/api/v1/status.json", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	var status nightguardStatusPayload
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode as nightguard's own status payload: %v", err)
	}
	if status.Settings.Units == "" {
		t.Fatal(`status.json's "settings.units" field is empty; nightguard's units(from:) rejects the site without it`)
	}
	if !strings.Contains(strings.ToLower(status.Settings.Units), "mg") {
		t.Errorf(`settings.units = %q, want it to name mg/dl (nightguard's units(from:) checks for "mg")`, status.Settings.Units)
	}
}

// TestStatusJSONDecodesAsAnObjectForLoopFollow checks that status.json's
// body decodes as a plain JSON object, which is all
// LoopFollow/Helpers/NightscoutUtils.swift's verifyURLAndToken (called
// from LoopFollow/Nightscout/NightscoutSettingsViewModel.swift when a
// person adds or edits a site) requires from any 200 response: it treats
// a missing "authorized" object as a read-only site rather than a
// rejection, and never requires any other field.
func TestStatusJSONDecodesAsAnObjectForLoopFollow(t *testing.T) {
	h, err := nightscout.New(&fakeStore{}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	rec := doRequest(t, h, "/api/v1/status.json", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	var asObject map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &asObject); err != nil {
		t.Fatalf("decode as a JSON object (LoopFollow's verifyURLAndToken requires this shape): %v", err)
	}
}

// TestExperimentsTest checks that the credential-test endpoint answers
// 200 for a valid credential. xDrip4iOS's own testNightscoutCredentials
// (NightscoutSyncManager.swift) calls this exact path and only checks
// that the request does not throw, discarding the body, so a 200 with any
// body is a shape it accepts.
func TestExperimentsTest(t *testing.T) {
	h, err := nightscout.New(&fakeStore{}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	rec := doRequest(t, h, "/api/v1/experiments/test", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
}

// TestEmptyCollectionEndpoints checks that treatments/devicestatus/
// profile each decode as a JSON array (the shape xDrip4iOS's
// NightscoutImportService decodes all three as), and that an empty relay
// answers with an empty array rather than an error.
func TestEmptyCollectionEndpoints(t *testing.T) {
	for _, path := range []string{
		"/api/v1/treatments.json",
		"/api/v1/devicestatus.json",
		"/api/v1/profile",
	} {
		t.Run(path, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			rec := doRequest(t, h, path, nil)
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
			}
			var got []json.RawMessage
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("decode as a JSON array: %v (body: %s)", err, rec.Body.String())
			}
			if len(got) != 0 {
				t.Errorf("got %d elements, want an empty array", len(got))
			}
		})
	}
}
