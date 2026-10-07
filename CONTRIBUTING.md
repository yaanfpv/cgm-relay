# Contributing to CGM Relay

Bug reports, ideas and pull requests are all welcome. The quickest way to report a bug is Report a Bug in the app (right-click the menu bar icon), which fills in your app version and build, macOS version and chip and nothing else, or [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new). Never paste your LibreLinkUp login, access token, relay address or readings into an issue. For anything bigger than a small fix, open an issue first so we can agree on the approach.

## What you need

- Go (the version in `go.mod`)
- Xcode 27 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), for the Mac app

You don't need a LibreLinkUp account: a fake LibreLinkUp server ships in the repo.

## The engine

The Go program that follows LibreLinkUp, stores readings and serves the Nightscout API lives in `cmd/cgm-relay` and `internal/`.

```bash
go test -race ./...
```

To run it end to end, start the fake server (`go run ./cmd/llufake`, which prints its port), then in a second terminal:

```bash
export CGM_RELAY_LIBRELINKUP_BASE_URL=http://127.0.0.1:PORT
export CGM_RELAY_EMAIL=follower@example.com CGM_RELAY_PASSWORD=anything CGM_RELAY_TOKEN=test-token
export CGM_RELAY_KEY=$(openssl rand -base64 32) CGM_RELAY_DATABASE_PATH=/tmp/cgm-relay-dev.db
export CGM_RELAY_LISTEN_ADDR=127.0.0.1:1357 CGM_RELAY_STATUS_ADDR=127.0.0.1:1358
go run ./cmd/cgm-relay serve
curl 'http://127.0.0.1:1357/api/v1/entries.json?count=1&token=test-token'
```

The ports stay clear of an installed CGM Relay, and a plain `http` LibreLinkUp address is accepted only on loopback.

## The Mac app

The checks table below has the commands that test and build it. A debug build never touches your real Keychain item, readings or login items, so it is safe on the Mac you use every day. With the fake server running, this launches it already signed in:

```bash
open "macos/.build/DerivedData/Build/Products/Debug/CGM Relay.app" --args \
  -CGMRelayKeychainService com.yaanfpv.cgmrelay.dev.mine \
  -CGMRelaySeedSyntheticAccount YES \
  -CGMRelayLibreLinkUpBaseURL http://127.0.0.1:PORT
```

| Argument | What it does |
| --- | --- |
| `-CGMRelayKeychainService <name>` | Keeps this run's account, settings and readings under `<name>`; a new name starts from a clean slate. The made-up account, the two fakes and the update feed need it. |
| `-CGMRelaySeedSyntheticAccount YES` | Signs in with a made-up account. |
| `-CGMRelayLibreLinkUpBaseURL <url>` | Points the engine at the fake server. |
| `-CGMRelayLoginItemFake <file>` | Open at Login reads and writes this file (`disabled`, `enabled`, `requiresApproval` or `notFound`). |
| `-CGMRelayTailscalePath <program>` | Runs this in place of Tailscale's command line tool. |
| `-CGMRelayUpdateFeedURL <url>` | Checks this appcast instead of the release feed (the build also needs `SPARKLE_PUBLIC_ED_KEY`). |

## Pull requests

Keep each one to one change, add or update tests for behaviour you change, and add one line under `## [Unreleased]` in `CHANGELOG.md` for someone using the app (a maintainer adds the `no changelog` label to a docs or CI change). Every pull request runs these checks, each a script in `.github/checks/` you can run yourself from the repository root, and a red one names the file and line:

| Check | Run it yourself |
| --- | --- |
| Go formatting | `gofmt -l .` (prints nothing when clean) |
| Go vet | `go vet ./...` |
| Go tests | `go test -race -count=1 ./...` |
| Go build | `go build ./...` |
| Swift tests | `swift test --package-path macos/Packages/CGMRelayCore` |
| Mac app build | `bash macos/scripts/build.sh CODE_SIGNING_ALLOWED=NO` |
| Changelog entry | `BASE_SHA=origin/main HEAD_SHA=HEAD bash .github/checks/changelog-entry.sh` |

## Releases

CGM Relay follows [Semantic Versioning](https://semver.org); the version is picked when a release is cut, never in a pull request. Maintainers cut one with `macos/scripts/release.sh X.Y.Z BUILD` (builds, signs and notarizes; publishes nothing), `macos/scripts/publish-release.sh X.Y.Z`, then `macos/scripts/verify-release.sh X.Y.Z`. Each script's header has the details.

## License

By contributing, you agree that your contribution is licensed under the [GNU Affero General Public License v3.0](LICENSE).
