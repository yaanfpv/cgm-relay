// Command llufake runs a standalone, runnable fake LibreLinkUp server for
// development use: it reuses the same in-process fake the Go test suite
// drives (internal/librelinkup/llufake), listening on an OS-assigned
// loopback port instead of one owned by a single test.
//
// Usage:
//
//	go run ./cmd/llufake
//
// It prints the base URL to point an engine at (cgm-relay's own
// librelinkup_base_url stdin configuration field, or CGM_RELAY_LIBRELINKUP_BASE_URL
// for a config file or environment install) and starts in "fresh" mode: a
// new current reading, timestamped now, on every request, so a poller
// signs in and immediately sees a flowing reading.
//
// While it is running, switch its mode at any time, with no restart, by
// posting to its own /mode endpoint:
//
//	curl -X POST "<url>/mode?mode=fresh"         # a current reading, taken just now
//	curl -X POST "<url>/mode?mode=stale"         # the last reading, fixed ten minutes old
//	curl -X POST "<url>/mode?mode=reject"        # every sign-in refused, as for a wrong password
//	curl -X POST "<url>/mode?mode=terms"         # every sign-in needs LibreLinkUp's updated terms accepted
//	curl -X POST "<url>/mode?mode=ratelimited"   # every sign-in answers 429, rate limited
//	curl -X POST "<url>/mode?mode=noconnections" # sign-in succeeds, but the account follows nobody
//	curl "<url>/mode"                            # print the current mode
//
// It runs until interrupted (Ctrl-C) or sent SIGTERM.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/yaanfpv/cgm-relay/internal/librelinkup/llufake"
)

func main() {
	srv := llufake.NewServer()
	defer srv.Close()

	if err := srv.SetMode("fresh"); err != nil {
		fmt.Fprintf(os.Stderr, "llufake: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("llufake: listening on %s\n", srv.URL)
	fmt.Println("llufake: starting in fresh mode; switch it at any time with:")
	fmt.Printf("  curl -X POST %q\n", srv.URL+"/mode?mode=fresh")
	fmt.Printf("  curl -X POST %q\n", srv.URL+"/mode?mode=stale")
	fmt.Printf("  curl -X POST %q\n", srv.URL+"/mode?mode=reject")
	fmt.Printf("  curl -X POST %q\n", srv.URL+"/mode?mode=terms")
	fmt.Printf("  curl -X POST %q\n", srv.URL+"/mode?mode=ratelimited")
	fmt.Printf("  curl -X POST %q\n", srv.URL+"/mode?mode=noconnections")
	fmt.Printf("  curl %q\n", srv.URL+"/mode")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	fmt.Println("llufake: shutting down")
}
