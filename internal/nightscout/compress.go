package nightscout

import (
	"compress/gzip"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// gzipMinSize is the smallest marshaled body writeJSON will ever gzip.
// Below it, gzip's own small container overhead can make the response
// larger, not smaller, so the majority-traffic steady-poll response
// (a few hundred bytes) is always written exactly as today.
const gzipMinSize = 1024

// gzipWriterPool reuses *gzip.Writer across requests instead of
// constructing one per request, which measurably costs more than
// resetting a pooled one.
var gzipWriterPool = sync.Pool{
	New: func() any { return gzip.NewWriter(nil) },
}

// qvaluePattern is RFC 9110 12.4.2's qvalue grammar: "0" followed by up to
// three decimal digits, or "1" followed by up to three trailing zeros. A
// weight outside this shape (more than three decimals, anything above 1,
// or non-numeric text) is not a qvalue at all, so the entry carrying it
// must be ignored rather than read as either an accept or a decline.
var qvaluePattern = regexp.MustCompile(`^(?:0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)$`)

// acceptEncodingEntry is one well-formed, comma-separated entry of a
// combined Accept-Encoding value: a lowercased coding token with its
// weight (defaulting to 1 when the entry carries no "q" parameter).
type acceptEncodingEntry struct {
	token  string
	weight float64
}

// parseAcceptEncoding splits header (every Accept-Encoding field line the
// request carried, already joined into one comma list per RFC 9110 5.3)
// into its well-formed entries, dropping any entry whose "q" parameter
// fails the qvalue grammar entirely: such an entry is never read as
// acceptance, exactly as if its token had not been listed at all.
func parseAcceptEncoding(header string) []acceptEncodingEntry {
	var entries []acceptEncodingEntry
	for _, part := range strings.Split(header, ",") {
		token, params, _ := strings.Cut(part, ";")
		token = strings.ToLower(strings.TrimSpace(token))
		if token == "" {
			continue
		}
		weight, ok := parseWeight(params)
		if !ok {
			continue
		}
		entries = append(entries, acceptEncodingEntry{token: token, weight: weight})
	}
	return entries
}

// parseWeight extracts params's "q" parameter (the text after a token's
// leading ";", e.g. "q=0" or " q=0.5") as a qvalue, defaulting to weight 1
// when the token carries no "q" parameter at all (RFC 9110 12.4.2's
// default). ok is false when a "q" parameter is present but its value is
// not a well-formed qvalue.
func parseWeight(params string) (weight float64, ok bool) {
	for _, p := range strings.Split(params, ";") {
		name, value, hasEq := strings.Cut(p, "=")
		if !hasEq || strings.ToLower(strings.TrimSpace(name)) != "q" {
			continue
		}
		value = strings.TrimSpace(value)
		if !qvaluePattern.MatchString(value) {
			return 0, false
		}
		q, err := strconv.ParseFloat(value, 64)
		return q, err == nil
	}
	return 1, true
}

// acceptsGzip reports whether header (every Accept-Encoding field line the
// request carried, combined into one list) accepts the gzip coding. Per
// RFC 9110 12.5.3, a well-formed explicit "gzip" entry (or its registered
// alias "x-gzip", 8.4.1.3) decides the outcome whenever one is present,
// whatever its own weight and wherever it sits relative to a "*" entry: a
// zero-weighted explicit entry is a decline, not silence, so it still
// overrides an unrelated "*" that would otherwise accept. Only when no
// well-formed explicit entry is present does a well-formed "*" entry
// decide instead. Token names are matched case-insensitively.
func acceptsGzip(header string) bool {
	var gzipWeight, starWeight float64
	var haveGzip, haveStar bool
	for _, e := range parseAcceptEncoding(header) {
		switch e.token {
		case "gzip", "x-gzip":
			if !haveGzip {
				haveGzip, gzipWeight = true, e.weight
			}
		case "*":
			if !haveStar {
				haveStar, starWeight = true, e.weight
			}
		}
	}
	if haveGzip {
		return gzipWeight > 0
	}
	return haveStar && starWeight > 0
}

// combinedAcceptEncoding joins every Accept-Encoding field line r carries
// into the one comma-separated list RFC 9110 5.3 says they are equivalent
// to, since a client is free to split a list-based field across more than
// one field line. r.Header.Get would silently see only the first such
// line. An absent header yields an empty string, same as one present with
// an empty value: acceptsGzip treats both as accepting nothing.
func combinedAcceptEncoding(r *http.Request) string {
	return strings.Join(r.Header.Values("Accept-Encoding"), ",")
}

// writeMaybeGzipped writes body as the response, gzip-encoding it only
// when r's combined Accept-Encoding accepts gzip and body is large enough
// that compression is worth its own container overhead. w must not have
// had Write or WriteHeader called on it yet, and must already carry
// Vary: Accept-Encoding (ServeHTTP sets it for every response before any
// handler runs, so an intermediary cache can never key a response on the
// URL alone and later serve a gzip body to a client that never asked for
// one, or vice versa). Content-Length is never set here in either branch,
// so whatever the server reports (if anything) is derived from the bytes
// actually written, never from body's own, pre-compression length.
func writeMaybeGzipped(w http.ResponseWriter, r *http.Request, body []byte) {
	if len(body) < gzipMinSize || !acceptsGzip(combinedAcceptEncoding(r)) {
		if _, err := w.Write(body); err != nil {
			log.Printf("nightscout: write response: %v", err)
		}
		return
	}

	w.Header().Set("Content-Encoding", "gzip")
	gz := gzipWriterPool.Get().(*gzip.Writer)
	gz.Reset(w)
	// Close, then Reset(io.Discard), then Put, in one deferred func. Close
	// is deferred rather than called at the end of the happy path only, so
	// a future edit that adds an early return after Write still flushes
	// gzip's own trailer instead of leaving a truncated stream every real
	// decoder rejects outright. Reset(io.Discard) runs before the writer
	// goes back in the pool, so it points at nothing once idle: without
	// it, a finished writer would sit in the pool still referencing this
	// request's ResponseWriter (and whatever that references) until next
	// reused, pinning it alive for no reason.
	defer func() {
		if err := gz.Close(); err != nil {
			log.Printf("nightscout: gzip response: close: %v", err)
		}
		gz.Reset(io.Discard)
		gzipWriterPool.Put(gz)
	}()
	if _, err := gz.Write(body); err != nil {
		log.Printf("nightscout: gzip response: %v", err)
	}
}
