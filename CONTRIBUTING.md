# Contributing to CGM Relay

To report a bug, use Report a Bug in the app (right-click the menu bar icon) or [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new), and keep your LibreLinkUp login, access token, relay address and readings out of it. For anything bigger than a small fix, open an issue before the pull request so we can agree on the approach.

## What you need

- Go (the version in `go.mod`)
- Xcode 27 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) for the Mac app

You don't need a LibreLinkUp account. A fake LibreLinkUp server ships in the repo.

## Running the engine

The engine is the Go program in `cmd/cgm-relay` and `internal/`. Start the fake server with `go run ./cmd/llufake` (it prints its port), then run this in a second terminal. The ports stay clear of an installed CGM Relay.

```bash
export CGM_RELAY_LIBRELINKUP_BASE_URL=http://127.0.0.1:PORT
export CGM_RELAY_EMAIL=follower@example.com CGM_RELAY_PASSWORD=anything CGM_RELAY_TOKEN=test-token
export CGM_RELAY_KEY=$(openssl rand -base64 32) CGM_RELAY_DATABASE_PATH=/tmp/cgm-relay-dev.db
export CGM_RELAY_LISTEN_ADDR=127.0.0.1:1357 CGM_RELAY_STATUS_ADDR=127.0.0.1:1358
go run ./cmd/cgm-relay serve
curl 'http://127.0.0.1:1357/api/v1/entries.json?count=1&token=test-token'
```

## Running the Mac app

Build it first with the Mac app build command under Pull requests. A debug build never touches your real Keychain item, readings or login items, so it's safe on the Mac you use every day. With the fake server running, this opens it already signed in. The seed, the two fakes and the update feed only work with your own `-CGMRelayKeychainService`.

```bash
open "macos/.build/DerivedData/Build/Products/Debug/CGM Relay.app" --args \
  -CGMRelayKeychainService com.yaanfpv.cgmrelay.dev.mine \
  -CGMRelaySeedSyntheticAccount YES \
  -CGMRelayLibreLinkUpBaseURL http://127.0.0.1:PORT
```

| Argument | What it does |
| --- | --- |
| `-CGMRelayKeychainService <name>` | Keeps this run's data under its own name. A new name starts clean. |
| `-CGMRelaySeedSyntheticAccount YES` | Signs in with a made-up account. |
| `-CGMRelayLibreLinkUpBaseURL <url>` | Points the engine at the fake server. |
| `-CGMRelayLoginItemFake <file>` | Fakes Open at Login with a file holding `disabled`, `enabled`, `requiresApproval` or `notFound`. |
| `-CGMRelayTailscalePath <program>` | Runs this instead of Tailscale's CLI. |
| `-CGMRelayUpdateFeedURL <url>` | Checks this appcast for updates (the build needs `SPARKLE_PUBLIC_ED_KEY`). |

## Pull requests

Keep each one to a single change, add tests for behaviour you change, and add a line under `## [Unreleased]` in `CHANGELOG.md` saying what changed for someone using the app. A docs or CI change can skip the changelog with the `no changelog` label.

Every pull request runs these checks. The four Go checks run side by side in one job, Go checks, so that's where they show up; the changelog entry is its own check, changelog, which adding or removing the label re-runs on its own. Each is a script in `.github/checks/`, and you can run the same command yourself from the repo root:

| Check | Command |
| --- | --- |
| Go formatting | `gofmt -l .` (prints nothing when clean) |
| Go vet | `go vet ./...` |
| Go tests | `go test -race -count=1 ./...` |
| Go build | `go build ./...` |
| Swift tests | `swift test --package-path macos/Packages/CGMRelayCore` |
| Mac app build | `bash macos/scripts/build.sh CODE_SIGNING_ALLOWED=NO` |
| Changelog entry | `BASE_SHA=origin/main HEAD_SHA=HEAD bash .github/checks/changelog-entry.sh` |

## Releases

CGM Relay follows [Semantic Versioning](https://semver.org). Releases are cut with the scripts in `macos/scripts/`, and each one's header explains it.

## License

By contributing, you agree your contribution is licensed under the [GNU AGPL-3.0](LICENSE).
