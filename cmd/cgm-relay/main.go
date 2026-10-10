// Command cgm-relay signs in to a cloud CGM account, polls it for glucose
// readings, and serves them over the Nightscout API for follower apps.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
	"github.com/yaanfpv/cgm-relay/internal/config"
	"github.com/yaanfpv/cgm-relay/internal/librelinkup"
	"github.com/yaanfpv/cgm-relay/internal/relay"
	"github.com/yaanfpv/cgm-relay/internal/store"
)

// exitCodeGenericFailure is returned for every serve failure this file does
// not otherwise distinguish.
const exitCodeGenericFailure = 1

// exitCodeStoreKeyMismatch is returned when the saved readings cannot be
// opened with the configured key: a permanent condition, unlike an ordinary
// crash, so a caller supervising this process (a menu bar app, say) can
// tell "restarting will not help" apart from every other failure by exit
// code alone, with no need to parse stderr. The macOS menu bar app's
// EngineSupervisor.storeKeyMismatchExitCode must always agree with this
// value.
const exitCodeStoreKeyMismatch = 3

// exitCodeStoreInUse is returned when another process already holds the
// saved readings open: also permanent from this process's own point of
// view, since restarting will keep losing the same race, though the other
// copy quitting can resolve it without either process changing anything.
// The macOS menu bar app's EngineSupervisor.storeInUseExitCode must
// always agree with this value.
const exitCodeStoreInUse = 4

// exitCodeStoreDamaged is returned when the saved readings file exists but
// cannot be read as a database at all: also permanent, since the same
// file will fail to open again every time. The macOS menu bar app's
// EngineSupervisor.storeDamagedExitCode must always agree with this
// value.
const exitCodeStoreDamaged = 5

// exitCodePortInUse is returned when the relay cannot listen on its follower
// port because another program already holds it: permanent from this
// process's own point of view, since restarting loses the same race. The
// macOS menu bar app's EngineSupervisor.portInUseExitCode must always agree
// with this value.
const exitCodePortInUse = 6

// The check-account exit codes below are returned only by the
// check-account command; every one is a permanent verdict about the
// account itself, never a reason to retry with the same credentials. The
// macOS menu bar app's Swift mirror of each constant (AccountCheckExitCode
// in CGMRelayCore) must always agree with these values.

// exitCodeAccountRejected is returned when LibreLinkUp rejects the email
// or password.
const exitCodeAccountRejected = 10

// exitCodeAccountTermsNotAccepted is returned when LibreLinkUp requires
// its updated terms to be accepted in its own app before this account can
// sign in again.
const exitCodeAccountTermsNotAccepted = 11

// exitCodeAccountNoConnections is returned when sign-in succeeds but the
// account follows nobody on LibreLinkUp.
const exitCodeAccountNoConnections = 12

// exitCodeAccountRateLimited is returned when LibreLinkUp is rate
// limiting sign-in attempts.
const exitCodeAccountRateLimited = 13

// exitCodeAccountUnreachable is returned when LibreLinkUp cannot be
// reached at all, or does not answer within checkAccountTimeout.
const exitCodeAccountUnreachable = 14

// checkAccountTimeout bounds check-account's whole sign-in-and-list
// attempt: generous next to LibreLinkUp's own ordinary response time, but
// short enough that a caller waiting on this command (the macOS menu bar
// app's Account pane) is never left hanging on a request that will never
// answer.
const checkAccountTimeout = 30 * time.Second

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
	case "check-account":
		runCheckAccount(os.Args[2:])
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
	fmt.Fprintln(w, "  setup          write a fresh configuration file and encryption key")
	fmt.Fprintln(w, "  serve          sign in, poll for readings, and serve the Nightscout API")
	fmt.Fprintln(w, "                 --config-stdin  read the configuration as one JSON object")
	fmt.Fprintln(w, "                                 from stdin, in place of the config file and")
	fmt.Fprintln(w, "                                 environment, and keep running only until")
	fmt.Fprintln(w, "                                 stdin closes, and print a line reading ready")
	fmt.Fprintln(w, "                                 on stdout once it is listening")
	fmt.Fprintln(w, "  check-account  read one JSON object on stdin (librelinkup_email,")
	fmt.Fprintln(w, "                 librelinkup_password, and optionally librelinkup_base_url)")
	fmt.Fprintln(w, "                 and confirm the account signs in and follows someone,")
	fmt.Fprintln(w, "                 without saving or serving anything")
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
// stop, which it treats as a clean shutdown rather than a failure. With
// --config-stdin, stdin itself is a second way to be told to stop: the
// caller (a menu bar app, say) holds it open for as long as it means the
// engine to keep running, so its own end reaches the engine even when
// nothing sends it a signal, and its stdout carries a single "ready" line
// once it is listening.
func runServe(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	configStdin := fs.Bool("config-stdin", false, "read the configuration as one JSON object from stdin, in place of the config file and environment, and keep running only until stdin closes")
	fs.Parse(args)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var cfg config.Config
	var loadErr error
	if *configStdin {
		cfg, loadErr = config.LoadFromReader(os.Stdin)
		if loadErr == nil {
			watchStdinForShutdown(os.Stdin, os.Stderr, stop)
		}
	} else {
		cfg, loadErr = config.Load()
	}
	if loadErr != nil {
		fmt.Fprintf(os.Stderr, "cgm-relay: serve: %v\n", loadErr)
		os.Exit(1)
	}

	if err := relay.Run(ctx, cfg, serveReadyOptions(*configStdin, os.Stdout)...); err != nil && !errors.Is(err, context.Canceled) {
		os.Exit(exitCodeForServeError(os.Stderr, err))
	}
}

// readyLine is the one line --config-stdin writes to stdout, once both
// listeners are bound. A supervising app waits for it before it presents
// the status secret, so the secret only ever reaches this process.
const readyLine = "ready\n"

// serveReadyOptions returns the option that writes readyLine to stdout once
// the relay is listening, and nothing for a plain serve, whose stdout stays
// empty.
func serveReadyOptions(configStdin bool, stdout io.Writer) []relay.Option {
	if !configStdin {
		return nil
	}
	return []relay.Option{relay.WithReady(func(relay.Addresses) {
		_, _ = io.WriteString(stdout, readyLine)
	})}
}

// exitCodeForServeError writes the line a person running `serve` should
// see for err to w, and returns the process exit code for it. Split out
// from runServe, which only calls os.Exit, so the choice itself is
// exercised by a test rather than only by a subprocess.
func exitCodeForServeError(w io.Writer, err error) int {
	switch {
	case errors.Is(err, store.ErrWrongKey):
		fmt.Fprintln(w, "cgm-relay: serve: the saved readings cannot be opened with this key")
		return exitCodeStoreKeyMismatch
	case errors.Is(err, store.ErrInUse):
		fmt.Fprintln(w, "cgm-relay: serve: the saved readings are already in use by another copy of CGM Relay")
		return exitCodeStoreInUse
	case errors.Is(err, store.ErrDamaged):
		fmt.Fprintln(w, "cgm-relay: serve: the saved readings file is damaged and cannot be read")
		return exitCodeStoreDamaged
	case errors.Is(err, relay.ErrPortInUse):
		fmt.Fprintf(w, "cgm-relay: serve: %v\n", err)
		return exitCodePortInUse
	default:
		fmt.Fprintf(w, "cgm-relay: serve: %v\n", err)
		return exitCodeGenericFailure
	}
}

// checkAccountRequest is the one JSON object check-account reads from
// stdin: exactly the three fields it needs, never the account's saved
// token or store key, since it never signs anything in and never talks to
// the store.
type checkAccountRequest struct {
	LibreLinkUpEmail    string `json:"librelinkup_email"`
	LibreLinkUpPassword string `json:"librelinkup_password"`
	LibreLinkUpBaseURL  string `json:"librelinkup_base_url"`
}

// runCheckAccount implements the check-account command: sign in with the
// stdin-supplied credentials and confirm the account follows someone,
// printing no secret and reporting the outcome only through its exit
// code (exitCodeForCheckAccountError's own doc comment names every one).
func runCheckAccount(args []string) {
	fs := flag.NewFlagSet("check-account", flag.ExitOnError)
	fs.Parse(args)

	var req checkAccountRequest
	dec := json.NewDecoder(os.Stdin)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		fmt.Fprintf(os.Stderr, "cgm-relay: check-account: parse stdin: %v\n", err)
		os.Exit(exitCodeGenericFailure)
	}
	if req.LibreLinkUpEmail == "" || req.LibreLinkUpPassword == "" {
		fmt.Fprintln(os.Stderr, "cgm-relay: check-account: librelinkup_email and librelinkup_password are required")
		os.Exit(exitCodeGenericFailure)
	}
	if !config.IsAllowedLibreLinkUpBaseURL(req.LibreLinkUpBaseURL) {
		fmt.Fprintf(os.Stderr, "cgm-relay: check-account: librelinkup_base_url must be https, or plain http to a loopback address, got %q\n", req.LibreLinkUpBaseURL)
		os.Exit(exitCodeGenericFailure)
	}

	var opts []librelinkup.Option
	if req.LibreLinkUpBaseURL != "" {
		opts = append(opts, librelinkup.WithBaseURL(req.LibreLinkUpBaseURL))
	}
	source := librelinkup.New(req.LibreLinkUpEmail, req.LibreLinkUpPassword, opts...)

	ctx, cancel := context.WithTimeout(context.Background(), checkAccountTimeout)
	defer cancel()
	os.Exit(exitCodeForCheckAccountError(os.Stderr, source.CheckAccount(ctx)))
}

// exitCodeForCheckAccountError writes the line a person should see for
// err to w, and returns check-account's own process exit code for it: 0
// for a nil err (signed in, and the account follows someone),
// exitCodeAccountRejected for a wrong email or password,
// exitCodeAccountTermsNotAccepted for LibreLinkUp's updated-terms prompt,
// exitCodeAccountNoConnections for a signed-in account nobody shares data
// with, exitCodeAccountRateLimited for a 429, exitCodeAccountUnreachable
// for a network failure or a timeout, and exitCodeGenericFailure for
// everything else. Split out from runCheckAccount, which only calls
// os.Exit, so the classification itself is exercised directly by a test.
func exitCodeForCheckAccountError(w io.Writer, err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, librelinkup.ErrInvalidCredentials):
		fmt.Fprintln(w, "cgm-relay: check-account: LibreLinkUp rejected the email or password")
		return exitCodeAccountRejected
	case errors.Is(err, librelinkup.ErrTermsNotAccepted):
		fmt.Fprintln(w, "cgm-relay: check-account: LibreLinkUp needs its updated terms accepted in its own app before this account can sign in")
		return exitCodeAccountTermsNotAccepted
	case errors.Is(err, librelinkup.ErrNoConnections):
		fmt.Fprintln(w, "cgm-relay: check-account: signed in, but this account follows nobody on LibreLinkUp")
		return exitCodeAccountNoConnections
	case errors.As(err, new(*cgm.RateLimitError)):
		fmt.Fprintln(w, "cgm-relay: check-account: LibreLinkUp is rate limiting sign-in attempts; try again later")
		return exitCodeAccountRateLimited
	case errors.As(err, new(*cgm.TransientError)), errors.Is(err, context.DeadlineExceeded):
		fmt.Fprintln(w, "cgm-relay: check-account: could not reach LibreLinkUp")
		return exitCodeAccountUnreachable
	default:
		fmt.Fprintf(w, "cgm-relay: check-account: %v\n", err)
		return exitCodeGenericFailure
	}
}

// watchStdinForShutdown reads r to EOF in the background, says so on
// logw, and then calls stop. r is the caller's own stdin under
// --config-stdin: the caller keeps it open for as long as it means the
// engine to run, so its own EOF -- a clean close, a crash, or a force
// quit, the OS closes every pipe a dead process still held open -- is the
// same "shut down" signal stop already carries for SIGTERM. The line on
// logw is what tells someone who piped in a file why the relay stopped.
func watchStdinForShutdown(r io.Reader, logw io.Writer, stop func()) {
	go func() {
		_, _ = io.Copy(io.Discard, r)
		fmt.Fprintln(logw, "cgm-relay: serve: stdin closed, shutting down")
		stop()
	}()
}
