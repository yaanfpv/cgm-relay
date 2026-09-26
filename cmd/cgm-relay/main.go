// Command cgm-relay signs in to a cloud CGM account, polls it for glucose
// readings, and serves them over the Nightscout API for follower apps.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/yaanfpv/cgm-relay/internal/config"
	"github.com/yaanfpv/cgm-relay/internal/relay"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "setup":
		runSetup(os.Args[2:])
	case "serve":
		runServe(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "cgm-relay: unknown command %q\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	printUsageTo(os.Stderr)
}

// printUsageTo writes the command usage summary to w, split out from
// printUsage so a test can check its content directly rather than
// capturing os.Stderr.
func printUsageTo(w io.Writer) {
	fmt.Fprintln(w, "usage: cgm-relay <command>")
	fmt.Fprintln(w, "commands:")
	fmt.Fprintln(w, "  setup   write a fresh configuration file and encryption key")
	fmt.Fprintln(w, "  serve   sign in, poll for readings, and serve the Nightscout API")
	fmt.Fprintln(w, "          --config-stdin  read the configuration as one JSON object")
	fmt.Fprintln(w, "                          from stdin, in place of the config file and")
	fmt.Fprintln(w, "                          environment")
}

// runSetup implements the setup command.
func runSetup(args []string) {
	fs := flag.NewFlagSet("setup", flag.ExitOnError)
	force := fs.Bool("force", false, "overwrite an existing configuration")
	fs.Parse(args)

	if _, err := config.Setup(os.Stdin, os.Stdout, *force); err != nil {
		fmt.Fprintf(os.Stderr, "cgm-relay: setup: %v\n", err)
		os.Exit(1)
	}
}

// runServe implements the serve command: it loads the configuration --
// from stdin as a single JSON object when --config-stdin is set,
// otherwise from the config file and environment as Load describes -- and
// runs the relay until an interrupt or termination signal asks it to
// stop, which it treats as a clean shutdown rather than a failure.
func runServe(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	configStdin := fs.Bool("config-stdin", false, "read the configuration as one JSON object from stdin, in place of the config file and environment")
	fs.Parse(args)

	var cfg config.Config
	var loadErr error
	if *configStdin {
		cfg, loadErr = config.LoadFromReader(os.Stdin)
	} else {
		cfg, loadErr = config.Load()
	}
	if loadErr != nil {
		fmt.Fprintf(os.Stderr, "cgm-relay: serve: %v\n", loadErr)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := relay.Run(ctx, cfg); err != nil && !errors.Is(err, context.Canceled) {
		fmt.Fprintf(os.Stderr, "cgm-relay: serve: %v\n", err)
		os.Exit(1)
	}
}
