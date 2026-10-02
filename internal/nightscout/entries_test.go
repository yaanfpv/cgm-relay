package nightscout_test

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
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

// manyReadings returns n readings one minute apart starting at base, in
// the same shape seedFive uses, generalized to sizes large enough to cross
// the gzip size floor.
func manyReadings(base time.Time, n int) []cgm.Reading {
	out := make([]cgm.Reading, n)
	for i := range out {
		out[i] = reading(base.Add(time.Duration(i)*time.Minute), 80+i%50)
	}
	return out
}

// doRequestAcceptEncoding issues an authenticated GET to path with query
// added, attaching one Accept-Encoding field line per entry in lines via
// net/http's own Header.Add, so more than one entry sends the header
// exactly as a client that split it across separate field lines would. A
// nil slice sends no Accept-Encoding header at all; a slice holding a
// single "" sends the header present with an empty value -- two shapes
// RFC 9110 12.5.3 both end up treating as "no gzip", by different paths,
// so a test needs a way to reach each one distinctly.
func doRequestAcceptEncoding(t *testing.T, h http.Handler, path string, query url.Values, lines []string) *httptest.ResponseRecorder {
	t.Helper()
	if query == nil {
		query = url.Values{}
	}
	if query.Get("token") == "" {
		query.Set("token", testToken)
	}
	req := httptest.NewRequest(http.MethodGet, path+"?"+query.Encode(), nil)
	for _, line := range lines {
		req.Header.Add("Accept-Encoding", line)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// decodeMaybeGzipped returns rec's body, gunzipped first if
// Content-Encoding says so, so a test can assert on one decoded byte slice
// regardless of which path fired.
func decodeMaybeGzipped(t *testing.T, rec *httptest.ResponseRecorder) []byte {
	t.Helper()
	if rec.Header().Get("Content-Encoding") != "gzip" {
		return rec.Body.Bytes()
	}
	gr, err := gzip.NewReader(bytes.NewReader(rec.Body.Bytes()))
	if err != nil {
		t.Fatalf("gzip.NewReader: %v", err)
	}
	defer gr.Close()
	out, err := io.ReadAll(gr)
	if err != nil {
		t.Fatalf("gunzip response body: %v", err)
	}
	return out
}

// TestWriteJSONCompressesOnlyWhenAskedAndLargeEnough is the table test
// over every Accept-Encoding shape the compression gate must parse per
// RFC 9110 12.5.3, driven through the real entries.json handler with a
// body large enough to cross the gzip size floor, plus the size-floor case
// itself. For every case it checks Vary is present, Content-Encoding
// matches whether compression should have fired, Content-Length (when set
// at all) matches the actual response bytes rather than the
// pre-compression size, the decoded body still ends with the trailing
// newline json.NewEncoder.Encode always wrote, and that decompressing (or,
// on the plain path, simply reading) the body yields exactly the same
// bytes a request with no Accept-Encoding header at all would have gotten
// for the same stored data -- the "follower apps see exactly the
// Nightscout shapes they parse today" invariant, checked byte for byte
// rather than merely field for field.
func TestWriteJSONCompressesOnlyWhenAskedAndLargeEnough(t *testing.T) {
	t.Parallel()
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	small := manyReadings(base, 5)   // well under the 1 KB gzip floor
	large := manyReadings(base, 500) // comfortably over it

	cases := []struct {
		name                string
		acceptEncodingLines []string
		readings            []cgm.Reading
		count               string
		wantCompressed      bool
	}{
		{"empty header", nil, large, "500", false},
		{"gzip accepted, small body stays plain (under the floor)", []string{"gzip"}, small, "5", false},
		{"plain gzip", []string{"gzip"}, large, "500", true},
		{"gzip among other codings", []string{"deflate, gzip, br"}, large, "500", true},
		{"uppercase token", []string{"GZIP"}, large, "500", true},
		{"mixed-case token", []string{"GzIp"}, large, "500", true},
		{"wildcard accepts everything", []string{"*"}, large, "500", true},
		{"gzip with q=0 explicitly refuses it", []string{"gzip;q=0"}, large, "500", false},
		{"gzip with q=0.000 explicitly refuses it", []string{"gzip;q=0.000"}, large, "500", false},
		{"gzip with a positive q accepts it", []string{"gzip;q=0.5"}, large, "500", true},
		{"gzip with q=1 accepts it", []string{"gzip;q=1"}, large, "500", true},
		{"wildcard with q=0 refuses everything, including gzip", []string{"*;q=0"}, large, "500", false},
		{"identity only, no gzip or wildcard token", []string{"identity"}, large, "500", false},
		{"gzip present alongside a zero-weighted wildcard", []string{"*;q=0, gzip"}, large, "500", true},
		{"whitespace around tokens and params", []string{" gzip ; q=0.3 "}, large, "500", true},
		{"trailing comma with no following token", []string{"gzip,"}, large, "500", true},
		// The rows below pin RFC 9110 12.5.3's negotiation rule in full,
		// including the cases the compression gate used to get wrong: an
		// explicit "gzip" entry, whatever its own weight, always decides
		// over a "*" entry, in either order; an alias or a malformed weight
		// is read correctly; and a client that splits Accept-Encoding across
		// more than one field line is honoured on the combined list, not
		// only its first line.
		{"explicit gzip refusal beats a following wildcard", []string{"gzip;q=0, *"}, large, "500", false},
		{"explicit gzip refusal beats a preceding wildcard", []string{"*, gzip;q=0"}, large, "500", false},
		{"the x-gzip alias is accepted", []string{"x-gzip"}, large, "500", true},
		{"uppercase token and uppercase q parameter name", []string{"GZIP;Q=0.5"}, large, "500", true},
		{"a q value above 1 is not a qvalue and is ignored", []string{"gzip;q=1.5"}, large, "500", false},
		{"a non-numeric q value is not a qvalue and is ignored", []string{"gzip;q=abc"}, large, "500", false},
		{"a q value with four decimal digits is not a qvalue and is ignored", []string{"gzip;q=0.0001"}, large, "500", false},
		{"gzip on a second field line is honoured, not only the first line's br", []string{"br", "gzip"}, large, "500", true},
		{"a refusal on the first field line still beats a wildcard on the second", []string{"gzip;q=0", "*"}, large, "500", false},
		{"the header present with an empty value, distinct from absent", []string{""}, large, "500", false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{readings: c.readings}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			rec := doRequestAcceptEncoding(t, h, "/api/v1/entries.json", url.Values{"count": {c.count}}, c.acceptEncodingLines)
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
			}

			if v := rec.Header().Get("Vary"); v != "Accept-Encoding" {
				t.Errorf("Vary = %q, want %q on every response", v, "Accept-Encoding")
			}

			gotCompressed := rec.Header().Get("Content-Encoding") == "gzip"
			if gotCompressed != c.wantCompressed {
				t.Fatalf("Content-Encoding = %q (compressed = %v), want compressed = %v", rec.Header().Get("Content-Encoding"), gotCompressed, c.wantCompressed)
			}

			if cl := rec.Header().Get("Content-Length"); cl != "" {
				n, err := strconv.Atoi(cl)
				if err != nil || n != rec.Body.Len() {
					t.Errorf("Content-Length = %q, want empty or exactly the recorded response length %d", cl, rec.Body.Len())
				}
			}

			decoded := decodeMaybeGzipped(t, rec)
			if len(decoded) == 0 || decoded[len(decoded)-1] != '\n' {
				t.Errorf("decoded body does not end with a newline, want the trailing newline json.NewEncoder.Encode always wrote: %q", decoded)
			}

			// Reference: the same store and the same request, but with no
			// Accept-Encoding header at all, so its response is never
			// compressed -- the exact bytes a client that never asks for
			// gzip receives today.
			refHandler, err := nightscout.New(&fakeStore{readings: c.readings}, testToken, nil)
			if err != nil {
				t.Fatalf("New (reference): %v", err)
			}
			ref := doRequestAcceptEncoding(t, refHandler, "/api/v1/entries.json", url.Values{"count": {c.count}}, nil)
			if !bytes.Equal(decoded, ref.Body.Bytes()) {
				t.Errorf("decompressed body differs from the uncompressed reference response\ndecoded: %s\nref:     %s", decoded, ref.Body.Bytes())
			}
		})
	}
}

// checkVaryAndStatus asserts rec's status is wantStatus and that it
// carries Vary: Accept-Encoding regardless, the one property every row in
// TestVaryAlwaysSetRegardlessOfStatus exists to check.
func checkVaryAndStatus(t *testing.T, rec *httptest.ResponseRecorder, wantStatus int) {
	t.Helper()
	if rec.Code != wantStatus {
		t.Fatalf("status = %d, want %d (body: %s)", rec.Code, wantStatus, rec.Body.String())
	}
	if v := rec.Header().Get("Vary"); v != "Accept-Encoding" {
		t.Errorf("Vary = %q, want %q", v, "Accept-Encoding")
	}
}

// TestVaryAlwaysSetRegardlessOfStatus checks that Vary: Accept-Encoding is
// on every response this handler writes, whatever its status: a 200 and a
// 401 on every registered endpoint, every 400 handleEntries can answer, a
// 500 from a failing reading source on both entries routes and current,
// and a 404 for a path this handler does not implement. Every one of
// these but the 200s bypasses writeJSON entirely, so a fix that set the
// header only there would miss them all silently.
func TestVaryAlwaysSetRegardlessOfStatus(t *testing.T) {
	t.Parallel()
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)

	t.Run("200 on every registered endpoint", func(t *testing.T) {
		for _, path := range nightscoutEndpoints {
			t.Run(path, func(t *testing.T) {
				h, err := nightscout.New(&fakeStore{}, testToken, nil)
				if err != nil {
					t.Fatalf("New: %v", err)
				}
				checkVaryAndStatus(t, doRequest(t, h, path, nil), http.StatusOK)
			})
		}
	})

	t.Run("401 on every registered endpoint that requires a credential", func(t *testing.T) {
		for _, path := range nightscoutEndpoints {
			if openEndpoints[path] {
				continue
			}
			t.Run(path, func(t *testing.T) {
				h, err := nightscout.New(&fakeStore{}, testToken, nil)
				if err != nil {
					t.Fatalf("New: %v", err)
				}
				req := httptest.NewRequest(http.MethodGet, path, nil)
				rec := httptest.NewRecorder()
				h.ServeHTTP(rec, req)
				checkVaryAndStatus(t, rec, http.StatusUnauthorized)
			})
		}
	})

	badInputCases := []struct {
		name  string
		query url.Values
	}{
		{"a malformed count", url.Values{"count": {"banana"}}},
		{"a malformed millisecond bound", url.Values{"find[date][$gte]": {"yesterday"}}},
		{"an unsupported find[date] operator", url.Values{"find[date][$ne]": {"1000"}}},
	}
	for _, c := range badInputCases {
		t.Run("400 on "+c.name, func(t *testing.T) {
			h, err := nightscout.New(&fakeStore{readings: seedFive(base)}, testToken, nil)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			checkVaryAndStatus(t, doRequest(t, h, "/api/v1/entries.json", c.query), http.StatusBadRequest)
		})
	}

	t.Run("500 from a failing reading source", func(t *testing.T) {
		for _, path := range []string{
			"/api/v1/entries.json",
			"/api/v1/entries/sgv.json",
			"/api/v1/entries/current.json",
		} {
			t.Run(path, func(t *testing.T) {
				h, err := nightscout.New(&fakeStore{err: errFakeStore}, testToken, nil)
				if err != nil {
					t.Fatalf("New: %v", err)
				}
				checkVaryAndStatus(t, doRequest(t, h, path, nil), http.StatusInternalServerError)
			})
		}
	})

	t.Run("404 for an unimplemented path", func(t *testing.T) {
		h, err := nightscout.New(&fakeStore{}, testToken, nil)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		req := httptest.NewRequest(http.MethodGet, "/api/v1/nonexistent.json", nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		checkVaryAndStatus(t, rec, http.StatusNotFound)
	})
}

// TestHeadRequestOnLargeGzippedResponse checks, through a real HTTP server
// rather than httptest.NewRecorder (which does not model HEAD-body
// suppression), that a HEAD request to a large, gzip-eligible
// entries.json response still reports the same headers the equivalent GET
// would while carrying no body: Go's transport layer suppresses a HEAD
// response's body, not the handler, so this compression logic is not
// exposed to a HEAD-specific truncation risk.
func TestHeadRequestOnLargeGzippedResponse(t *testing.T) {
	t.Parallel()
	base := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	h, err := nightscout.New(&fakeStore{readings: manyReadings(base, 500)}, testToken, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()

	req, err := http.NewRequest(http.MethodHead, srv.URL+"/api/v1/entries.json?token="+testToken+"&count=500", nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("HEAD request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ce := resp.Header.Get("Content-Encoding"); ce != "gzip" {
		t.Errorf("Content-Encoding = %q, want %q", ce, "gzip")
	}
	if v := resp.Header.Get("Vary"); v != "Accept-Encoding" {
		t.Errorf("Vary = %q, want %q", v, "Accept-Encoding")
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read HEAD response body: %v", err)
	}
	if len(body) != 0 {
		t.Errorf("HEAD response body has %d bytes, want 0", len(body))
	}
}
