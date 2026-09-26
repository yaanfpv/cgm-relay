package nightscout_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/nightscout"
)

// jsonEntry mirrors the entries API's required field set, decoded loosely
// (as any real follower app JSON-decodes it) rather than against the
// package's own unexported entry type.
type jsonEntry struct {
	ID         string `json:"_id"`
	Type       string `json:"type"`
	SGV        int    `json:"sgv"`
	Date       int64  `json:"date"`
	DateString string `json:"dateString"`
	Direction  string `json:"direction"`
	Device     string `json:"device"`
}

// getEntries issues an authenticated GET to path with the given query
// values added (a "token" is always included) and decodes the JSON array
// response. It fails the test on a non-200 status or malformed body, so
// callers that expect an error use doRequest directly instead.
func getEntries(t *testing.T, h http.Handler, path string, query url.Values) []jsonEntry {
	t.Helper()
	rec := doRequest(t, h, path, query)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s%s: status = %d, body = %s", path, queryString(query), rec.Code, rec.Body.String())
	}
	var got []jsonEntry
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response body %q: %v", rec.Body.String(), err)
	}
	return got
}

// doRequest issues an authenticated GET to path with query added, and
// returns the raw recorder so a caller can inspect the status directly.
func doRequest(t *testing.T, h http.Handler, path string, query url.Values) *httptest.ResponseRecorder {
	t.Helper()
	if query == nil {
		query = url.Values{}
	}
	if query.Get("token") == "" {
		query.Set("token", testToken)
	}
	req := httptest.NewRequest(http.MethodGet, path+"?"+query.Encode(), nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func queryString(query url.Values) string {
	if len(query) == 0 {
		return ""
	}
	return "?" + query.Encode()
}

func mgDlsOfEntries(entries []jsonEntry) []int {
	out := make([]int, len(entries))
	for i, e := range entries {
		out[i] = e.SGV
	}
	return out
}

func assertMgDlSequence(t *testing.T, got []jsonEntry, want []int) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %d entries, want %d (sgv=%v)", len(got), len(want), mgDlsOfEntries(got))
	}
	for i, w := range want {
		if got[i].SGV != w {
			t.Errorf("entry %d: sgv = %d, want %d (full sgv sequence got=%v, want=%v)", i, got[i].SGV, w, mgDlsOfEntries(got), want)
		}
	}
}

// TestEntriesFieldShape checks, on a single reading, that every field a
// follower app reads is present with the right type and value, including
// that direction comes through as Nightscout's own name (via
// cgm.Trend.String, not reimplemented here) and date is milliseconds.
func TestEntriesFieldShape(t *testing.T) {
	base := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	fs := &fakeStore{readings: []cgm.Reading{
		{Time: base, MgDl: 142, Trend: cgm.TrendFortyFiveDown, Source: "librelinkup"},
	}}
	h, err := nightscout.New(fs, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	got := getEntries(t, h, "/api/v1/entries/sgv.json", nil)
	if len(got) != 1 {
		t.Fatalf("got %d entries, want 1", len(got))
	}
	e := got[0]
	if e.Type != "sgv" {
		t.Errorf("type = %q, want %q", e.Type, "sgv")
	}
	if e.SGV != 142 {
		t.Errorf("sgv = %d, want 142", e.SGV)
	}
	if want := base.UnixMilli(); e.Date != want {
		t.Errorf("date = %d, want %d", e.Date, want)
	}
	if e.DateString != "2026-06-01T12:00:00.000Z" {
		t.Errorf("dateString = %q, want %q", e.DateString, "2026-06-01T12:00:00.000Z")
	}
	if e.Direction != "FortyFiveDown" {
		t.Errorf("direction = %q, want %q", e.Direction, "FortyFiveDown")
	}
	if e.Device != "librelinkup" {
		t.Errorf("device = %q, want %q", e.Device, "librelinkup")
	}
	if e.ID == "" {
		t.Error("_id is empty, want a stable non-empty id")
	}
}

// TestEntriesIDIsStableForTheSameReading checks that _id does not change
// between two requests for the same stored reading, since a follower app
// may use it to deduplicate.
func TestEntriesIDIsStableForTheSameReading(t *testing.T) {
	base := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	fs := &fakeStore{readings: []cgm.Reading{reading(base, 100)}}
	h, err := nightscout.New(fs, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	first := getEntries(t, h, "/api/v1/entries.json", nil)
	second := getEntries(t, h, "/api/v1/entries.json", nil)
	if first[0].ID != second[0].ID {
		t.Errorf("_id changed across requests: %q then %q", first[0].ID, second[0].ID)
	}
}

// TestEntriesOrderedNewestFirst and the count/bound tests below check the
// entries request shapes: entries/sgv.json and entries.json behave
// identically here since every stored reading is an sgv entry.
func TestEntriesOrderedNewestFirst(t *testing.T) {
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	fs := &fakeStore{readings: seedFive(base)}

	for _, path := range []string{"/api/v1/entries/sgv.json", "/api/v1/entries.json"} {
		t.Run(path, func(t *testing.T) {
			h, err := nightscout.New(fs, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			got := getEntries(t, h, path, nil)
			assertMgDlSequence(t, got, []int{5, 4, 3, 2, 1})
		})
	}
}

// seedFive returns five readings one minute apart starting at base, MgDl
// 1..5 in time order, so tests can identify which rows a query returned.
func seedFive(base time.Time) []cgm.Reading {
	out := make([]cgm.Reading, 5)
	for i := range out {
		out[i] = reading(base.Add(time.Duration(i)*time.Minute), i+1)
	}
	return out
}

func TestEntriesDefaultCountIsTen(t *testing.T) {
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	readings := make([]cgm.Reading, 15)
	for i := range readings {
		readings[i] = reading(base.Add(time.Duration(i)*time.Minute), i+1)
	}
	h, err := nightscout.New(&fakeStore{readings: readings}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	got := getEntries(t, h, "/api/v1/entries.json", nil)
	assertMgDlSequence(t, got, []int{15, 14, 13, 12, 11, 10, 9, 8, 7, 6})
}

func TestEntriesExplicitCount(t *testing.T) {
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	h, err := nightscout.New(&fakeStore{readings: seedFive(base)}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	got := getEntries(t, h, "/api/v1/entries.json", url.Values{"count": {"2"}})
	assertMgDlSequence(t, got, []int{5, 4})
}

// TestEntriesDateBounds checks millisecond-exact bound semantics against
// readings one minute apart (so a whole-second boundary falls exactly on
// a reading) AND against bounds that land inside a second (so no
// reading's timestamp equals the bound exactly), which is the case
// xDrip4iOS's gap audit sends (find[date][$lt] computed from a wall-clock
// interval, not from a stored reading's own timestamp).
func TestEntriesDateBounds(t *testing.T) {
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	// minute i has MgDl i+1, so minute 2 (MgDl 3) is date base+2min in ms.
	seed := seedFive(base)
	minuteMs := func(i int) int64 { return base.Add(time.Duration(i) * time.Minute).UnixMilli() }

	cases := []struct {
		name  string
		query url.Values
		want  []int
	}{
		{
			name:  "gte exactly on a reading's timestamp keeps it",
			query: url.Values{"find[date][$gte]": {itoa64(minuteMs(2))}},
			want:  []int{5, 4, 3},
		},
		{
			name:  "gte 1ms after a reading's timestamp excludes it",
			query: url.Values{"find[date][$gte]": {itoa64(minuteMs(2) + 1)}},
			want:  []int{5, 4},
		},
		{
			name:  "lt exactly on a reading's timestamp excludes it",
			query: url.Values{"find[date][$lt]": {itoa64(minuteMs(2))}},
			want:  []int{2, 1},
		},
		{
			name:  "lt 1ms after a reading's timestamp keeps it",
			query: url.Values{"find[date][$lt]": {itoa64(minuteMs(2) + 1)}},
			want:  []int{3, 2, 1},
		},
		{
			name:  "lte exactly on a reading's timestamp keeps it",
			query: url.Values{"find[date][$lte]": {itoa64(minuteMs(2))}},
			want:  []int{3, 2, 1},
		},
		{
			name:  "lte 1ms before a reading's timestamp excludes it",
			query: url.Values{"find[date][$lte]": {itoa64(minuteMs(2) - 1)}},
			want:  []int{2, 1},
		},
		{
			name:  "gte and lt combine to a half-open window",
			query: url.Values{"find[date][$gte]": {itoa64(minuteMs(1))}, "find[date][$lt]": {itoa64(minuteMs(4))}},
			want:  []int{4, 3, 2},
		},
		{
			name:  "gt exactly on a reading's timestamp excludes it",
			query: url.Values{"find[date][$gt]": {itoa64(minuteMs(2))}},
			want:  []int{5, 4},
		},
		{
			name:  "gt 1ms before a reading's timestamp keeps it",
			query: url.Values{"find[date][$gt]": {itoa64(minuteMs(2) - 1)}},
			want:  []int{5, 4, 3},
		},
		{
			name: "gte and gt combine to the tighter of the two",
			query: url.Values{
				"find[date][$gte]": {itoa64(minuteMs(1))}, // would alone keep minute 1..4
				"find[date][$gt]":  {itoa64(minuteMs(2))}, // stricter: only minute 3..4
			},
			want: []int{5, 4},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{readings: seed}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			c.query.Set("count", "10")
			got := getEntries(t, h, "/api/v1/entries.json", c.query)
			assertMgDlSequence(t, got, c.want)
		})
	}
}

// TestEntriesDateBoundsBeforeEpoch checks that the millisecond-to-second
// conversion is correct for a negative bound too (a pre-1970 date), since
// Go's own integer division truncates toward zero rather than flooring,
// which is the wrong direction below zero.
func TestEntriesDateBoundsBeforeEpoch(t *testing.T) {
	base := time.Unix(-120, 0).UTC() // two minutes before the Unix epoch
	seed := seedFive(base)
	minuteMs := func(i int) int64 { return base.Add(time.Duration(i) * time.Minute).UnixMilli() }

	cases := []struct {
		name  string
		query url.Values
		want  []int
	}{
		{
			name:  "gte on a negative value divisible by 1000",
			query: url.Values{"find[date][$gte]": {itoa64(minuteMs(1))}}, // -60000
			want:  []int{5, 4, 3, 2},
		},
		{
			name:  "gte on a negative value inside a second",
			query: url.Values{"find[date][$gte]": {itoa64(minuteMs(1) + 500)}}, // -59500
			want:  []int{5, 4, 3},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{readings: seed}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			c.query.Set("count", "10")
			got := getEntries(t, h, "/api/v1/entries.json", c.query)
			assertMgDlSequence(t, got, c.want)
		})
	}
}

// TestCurrentEntry checks the newest-single-reading endpoint, both with
// data and with an empty store (a follower's very first poll).
func TestCurrentEntry(t *testing.T) {
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)

	t.Run("with readings, returns the newest one", func(t *testing.T) {
		h, err := nightscout.New(&fakeStore{readings: seedFive(base)}, testToken, nil)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		got := getEntries(t, h, "/api/v1/entries/current.json", nil)
		assertMgDlSequence(t, got, []int{5})
	})

	t.Run("with no readings, returns an empty array", func(t *testing.T) {
		h, err := nightscout.New(&fakeStore{}, testToken, nil)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		got := getEntries(t, h, "/api/v1/entries/current.json", nil)
		if len(got) != 0 {
			t.Errorf("got %d entries, want 0", len(got))
		}
	})
}

// TestEntriesMalformedParametersReturn400 checks that a non-numeric count
// or date bound answers 400 with a plain message, never a panic and never
// data returned as though the bound were absent.
func TestEntriesMalformedParametersReturn400(t *testing.T) {
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)

	cases := []struct {
		name  string
		query url.Values
	}{
		{"count is not a number", url.Values{"count": {"banana"}}},
		{"count is negative", url.Values{"count": {"-1"}}},
		{"count has a decimal point", url.Values{"count": {"2.5"}}},
		{"gte is not a number", url.Values{"find[date][$gte]": {"yesterday"}}},
		{"gte has a decimal point", url.Values{"find[date][$gte]": {"1000.5"}}},
		{"lt is not a number", url.Values{"find[date][$lt]": {"soon"}}},
		{"lte is not a number", url.Values{"find[date][$lte]": {"later"}}},
		{"an unsupported find[date] operator", url.Values{"find[date][$ne]": {"1000"}}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{readings: seedFive(base)}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			rec := doRequest(t, h, "/api/v1/entries.json", c.query)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d (body: %s)", rec.Code, http.StatusBadRequest, rec.Body.String())
			}
			ct := rec.Header().Get("Content-Type")
			if want := "text/plain; charset=utf-8"; ct != want {
				t.Errorf("Content-Type = %q, want %q (a plain message, not JSON)", ct, want)
			}
			if rec.Body.Len() == 0 {
				t.Error("400 response body is empty, want a message naming the problem")
			}
		})
	}
}

func itoa64(n int64) string {
	return strconv.FormatInt(n, 10)
}

// TestEntriesStoreErrorReturns500 checks that a failure reading the store
// surfaces as a 500 rather than a panic or a response claiming success.
func TestEntriesStoreErrorReturns500(t *testing.T) {
	for _, path := range []string{"/api/v1/entries.json", "/api/v1/entries/current.json"} {
		t.Run(path, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{err: errFakeStore}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			rec := doRequest(t, h, path, nil)
			if rec.Code != http.StatusInternalServerError {
				t.Fatalf("status = %d, want %d (body: %s)", rec.Code, http.StatusInternalServerError, rec.Body.String())
			}
		})
	}
}

// TestEntriesLimitsStoreQuery checks that the store is asked for no more
// rows than the response can use: a count=2 request over 20 stored
// readings asks the store for exactly 2 rows, and a count=0 request never
// queries the store at all.
func TestEntriesLimitsStoreQuery(t *testing.T) {
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	readings := make([]cgm.Reading, 20)
	for i := range readings {
		readings[i] = reading(base.Add(time.Duration(i)*time.Minute), i+1)
	}

	t.Run("count=2 asks the store for exactly 2 rows", func(t *testing.T) {
		fs := &fakeStore{readings: readings}
		h, err := nightscout.New(fs, testToken, nil)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		got := getEntries(t, h, "/api/v1/entries.json", url.Values{"count": {"2"}})
		assertMgDlSequence(t, got, []int{20, 19})
		if fs.lastQuery.Limit != 2 {
			t.Errorf("store was asked with Limit = %d, want exactly 2", fs.lastQuery.Limit)
		}
	})

	t.Run("count=0 never queries the store", func(t *testing.T) {
		fs := &fakeStore{readings: readings}
		h, err := nightscout.New(fs, testToken, nil)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		got := getEntries(t, h, "/api/v1/entries.json", url.Values{"count": {"0"}})
		if len(got) != 0 {
			t.Errorf("got %d entries for count=0, want 0", len(got))
		}
		if fs.rangeCalls != 0 {
			t.Errorf("store.Range was called %d time(s) for count=0, want 0", fs.rangeCalls)
		}
	})

	t.Run("a date-bounded request still asks for only count rows", func(t *testing.T) {
		fs := &fakeStore{readings: readings}
		h, err := nightscout.New(fs, testToken, nil)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		gte := base.Add(time.Minute).UnixMilli()
		got := getEntries(t, h, "/api/v1/entries.json", url.Values{
			"count":            {"3"},
			"find[date][$gte]": {itoa64(gte)},
		})
		assertMgDlSequence(t, got, []int{20, 19, 18})
		if fs.lastQuery.Limit != 3 {
			t.Errorf("store was asked with Limit = %d, want exactly 3", fs.lastQuery.Limit)
		}
	})
}
