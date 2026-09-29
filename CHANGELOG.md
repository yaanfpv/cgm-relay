# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

- Add CGM Relay's own app icon, so the Dock and Finder show it instead of a generic blank tile.
- Fix CI so it stops warning about deprecated Node runtimes: `checkout` and `setup-go` are now pinned to their current releases, both running on Node 24.
- Compress a large Nightscout API response with gzip when the requesting app asks for it, so a follower catching up on hours of history downloads far fewer bytes over a slow connection; a small response, or a request that never asks for gzip, is written exactly as before.
- Fix the local status endpoint's follower-client list so it can no longer grow without bound: it now keeps the 256 most recently seen clients and drops the longest-silent one to make room for a new one.
- Add the reading model, source interface, and an encrypted SQLite store for glucose readings.
- Add a LibreLinkUp source that signs in, follows region redirects, and refreshes an expired session automatically.
- Add the minute-by-minute poller that fetches readings, fills history gaps, backs off on rate limits and auth failures, and prunes old readings on start and once a day.
- Add a Nightscout-compatible API handler so follower apps like xDrip4iOS can poll the relay for entries, status, and current readings.
- Add a `setup` command that writes a config file and encryption key, with environment variable overrides for Docker.
- Add a `serve` command that signs in, polls, and serves the Nightscout API together, with `status.json` fields xDrip4iOS, LoopFollow, and Nightguard each need to accept the site.
- Add a loopback-only local status endpoint reporting poller health and which follower clients are actually polling, for the menu bar app and headless installs alike.
- Add `serve --config-stdin`, which reads the whole configuration as one JSON object on stdin instead of the config file or environment, so a caller holding secrets in a keychain never has to write them to disk or the process environment. The relay then runs until stdin closes, so it never outlives the caller.
- Fix the Nightscout API to accept every credential form and connection probe that xDrip4iOS, xDrip+, LoopFollow, and Nightguard actually send: a path the relay does not implement now answers 404 before any credential check, and an `api-secret` header carrying the raw access token (not only its SHA-1 hash) is now accepted.
- Add the macOS menu bar app: a status dot, current reading, and follower activity read from the engine's status endpoint, with the engine supervised as a child process and restarted with backoff if it stops unexpectedly.
- Add a standalone runnable fake LibreLinkUp server (`go run ./cmd/llufake`) and an optional `librelinkup_base_url` configuration field, so the engine and the menu bar app can be driven through every status state without a real account.
- Fix the menu bar app so a saved reading database this Mac's key can no longer open (after a Keychain reset, a restored backup, or a move to a new Mac) is recognised instead of restarted forever: the menu now explains what happened and offers a "Start Fresh…" recovery that moves the old file aside, never deleting it.
- Fix two copies of the menu bar app opened at once so only one of them ever uses the saved readings: the other says so plainly and offers to try again the moment the first one quits, instead of restarting forever. Fix a saved reading database that cannot be read at all, not just one sealed with the wrong key, to get the same "Start Fresh…" recovery instead of restarting forever. Fix the menu so stopping the engine keeps showing the last reading it saw, instead of claiming there had never been one.
- Fix the menu bar app so the engine it starts gets an explicit, minimal set of environment variables instead of this app's own whole environment: nothing the engine needs ever arrives that way, since its configuration is exactly what the app writes to its standard input.
- Fix a development build of the menu bar app so a launch given no development Keychain service argument uses a fixed development service and its own database folder, instead of the real Keychain item and the real reading database.
- Add the Settings window: sign in and out of a LibreLinkUp account, checked against LibreLinkUp before anything is saved (`cgm-relay check-account`); a Connect pane showing the follower address, token, and a QR code, with a way to rotate the token; General, Advanced, and About panes for login-at-startup, units, retention, port, and who can reach the relay (this Mac, a Tailscale tailnet, or the local network); and two optional notifications, for no new reading in a while and for sign-in failing.
