# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

- Add the reading model, source interface, and an encrypted SQLite store for glucose readings.
- Add a LibreLinkUp source that signs in, follows region redirects, and refreshes an expired session automatically.
- Add the minute-by-minute poller that fetches readings, fills history gaps, backs off on rate limits and auth failures, and prunes old readings on start and once a day.
- Add a Nightscout-compatible API handler so follower apps like xDrip4iOS can poll the relay for entries, status, and current readings.
- Add a `setup` command that writes a config file and encryption key, with environment variable overrides for Docker.
- Add a `serve` command that signs in, polls, and serves the Nightscout API together, with `status.json` fields xDrip4iOS, LoopFollow, and Nightguard each need to accept the site.
- Add a loopback-only local status endpoint reporting poller health and which follower clients are actually polling, for the menu bar app and headless installs alike.
- Add `serve --config-stdin`, which reads the whole configuration as one JSON object on stdin instead of the config file or environment, so a caller holding secrets in a keychain never has to write them to disk or the process environment.
