package main

import (
	"bytes"
	"strings"
	"testing"
)

// TestUsageListsConfigStdinFlag checks that the usage summary printed
// with no arguments (or an unknown command) mentions --config-stdin, so a
// caller wiring cgm-relay in from a menu bar app can discover the flag
// without reading source.
func TestUsageListsConfigStdinFlag(t *testing.T) {
	var buf bytes.Buffer
	printUsageTo(&buf)
	if !strings.Contains(buf.String(), "--config-stdin") {
		t.Errorf("usage = %q, want it to mention --config-stdin", buf.String())
	}
}
