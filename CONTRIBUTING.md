# Contributing to CGM Relay

Thanks for wanting to help. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug or asking for a feature

The quickest way is Report a Bug in the app (right-click the menu bar icon), or Report a Bug or Suggest a Feature in Settings > About. It opens a GitHub issue with your app version and build, macOS version and chip filled in, and nothing else. Or [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new) directly.

Please never paste your LibreLinkUp email or password, your access token, your relay's address or your readings into an issue.

For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## What you need

- Go (the version in `go.mod`)
- Xcode 27 or later, for the Mac app (it builds with the macOS 27 SDK and runs on macOS 15 and later)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), which generates the Xcode project from `macos/project.yml`

You don't need a LibreLinkUp account. Everything can run against a fake LibreLinkUp server that ships in the repo.

## The engine

The engine is the Go program that follows LibreLinkUp, stores readings and serves the Nightscout API. It lives in `cmd/cgm-relay` and `internal/`.

```bash
go test -race ./...
go vet ./...
gofmt -l .
```

To run it end to end without a real account, start the fake LibreLinkUp server in one terminal. It prints the address it listens on:

```bash
go run ./cmd/llufake
```

Then, in a second terminal, point the engine at that address with made-up credentials:

```bash
export CGM_RELAY_LIBRELINKUP_BASE_URL=http://127.0.0.1:PORT
export CGM_RELAY_EMAIL=follower@example.com CGM_RELAY_PASSWORD=anything CGM_RELAY_TOKEN=test-token
export CGM_RELAY_KEY=$(openssl rand -base64 32)
export CGM_RELAY_DATABASE_PATH=/tmp/cgm-relay-dev.db
export CGM_RELAY_LISTEN_ADDR=127.0.0.1:1357 CGM_RELAY_STATUS_ADDR=127.0.0.1:1358
go run ./cmd/cgm-relay serve
```

Replace `PORT` with the one the fake printed. The two addresses keep this run off the default ports (1337 and 1338), so it works even while an installed CGM Relay is running. Within a few seconds the relay has a reading, and a follower app or `curl` can read it:

```bash
curl 'http://127.0.0.1:1357/api/v1/entries.json?count=1&token=test-token'
```

The engine accepts a plain `http` LibreLinkUp address only on your own machine (loopback), so this override can never point a real install at an unencrypted server.

## The Mac app

The Mac app is a SwiftUI menu bar app in `macos/`. Its logic lives in the `CGMRelayCore` package, which has its own tests:

```bash
swift test --package-path macos/Packages/CGMRelayCore
```

Build the app, with the engine embedded, for both Apple silicon and Intel:

```bash
bash macos/scripts/build.sh CODE_SIGNING_ALLOWED=NO
```

A debug build never touches your real Keychain item, reading database or login items, so it is safe to run on the Mac you use every day.

It keeps its account, settings and readings under a Keychain service of its own. With no arguments it uses `com.yaanfpv.cgmrelay.dev.default`; give it a name of your own to start from a clean slate. With the fake LibreLinkUp server from the engine section running, this launches the app already signed in:

```bash
open "macos/.build/DerivedData/Build/Products/Debug/CGM Relay.app" --args \
  -CGMRelayKeychainService com.yaanfpv.cgmrelay.dev.mine \
  -CGMRelaySeedSyntheticAccount YES \
  -CGMRelayLibreLinkUpBaseURL http://127.0.0.1:PORT
```

| Argument | What it does |
| --- | --- |
| `-CGMRelayKeychainService <name>` | Keeps this run's account, settings and readings under `<name>`. It must be a single plain name and never the app's own service; anything else stops the app at launch. |
| `-CGMRelaySeedSyntheticAccount YES` | Signs in with a made-up account, so you can skip setup's first step. Only works together with your own `-CGMRelayKeychainService`. |
| `-CGMRelayLibreLinkUpBaseURL <url>` | Points the engine at the fake LibreLinkUp server. |
| `-CGMRelayLoginItemFake <file>` | Open at Login reads and writes this file instead of your real login items. The file holds one word: `disabled`, `enabled`, `requiresApproval` or `notFound`. Without it, a debug build shows Open at Login as not available. |
| `-CGMRelayTailscalePath <program>` | Runs this program in place of Tailscale's command line tool. Without it, a debug build never touches your real Tailscale and behaves as if it isn't installed. |
| `-CGMRelayUpdateFeedURL <url>` | Checks this appcast for updates instead of the release feed, for trying the updater against a feed you serve yourself. The build also needs a public key (`SPARKLE_PUBLIC_ED_KEY=<key>` on the build command); without one the updater never starts. |

The two fakes and the update feed, like the made-up account, work only together with your own `-CGMRelayKeychainService`. To run setup again, quit the app and remove that run's settings and readings:

```bash
defaults delete com.yaanfpv.cgmrelay.dev.mine
rm -rf ~/"Library/Application Support/CGM Relay/Development/com.yaanfpv.cgmrelay.dev.mine"
```

The account, access token and encryption key stay in your login keychain under that name, so setup reopens with the account still signed in. To start with no account at all, launch with a new `-CGMRelayKeychainService` name instead.

## Pull requests

- Keep each pull request to one change, with a clear title and a description of what it does and why.
- Add or update tests for behaviour you change, in the existing test files where the change fits.
- Add one line under `## [Unreleased]` in `CHANGELOG.md` describing the change for someone using the app.

Every pull request runs seven checks, each its own entry in the pull request's checks list. A red one names the file and line where there is one, and shows the command to run to see it yourself. Each command below runs from the repository root, and each check is a script in `.github/checks/` that CI runs as is.

| Check | What it looks at | Run it yourself |
| --- | --- | --- |
| Go formatting | Every Go file is gofmt-formatted and parses | `gofmt -l .` (it should print nothing; `gofmt -w .` fixes formatting) |
| Go vet | `go vet` finds nothing | `go vet ./...` |
| Go tests | The engine's tests pass, with the race detector | `go test -race -count=1 ./...` |
| Go build | The engine builds | `go build ./...` |
| Swift tests | The `CGMRelayCore` package's tests pass | `swift test --package-path macos/Packages/CGMRelayCore` |
| Mac app build | The app builds, with the engine embedded | `bash macos/scripts/build.sh CODE_SIGNING_ALLOWED=NO` |
| Changelog entry | Your change adds a line under `## [Unreleased]` | `BASE_SHA=origin/main HEAD_SHA=HEAD bash .github/checks/changelog-entry.sh` |

A change that needs no changelog line (documentation or CI only) can skip Changelog entry: ask a maintainer to add the `no changelog` label.

## Versioning

CGM Relay follows [Semantic Versioning](https://semver.org). A minor release (1.1.0) adds features, a patch release (1.0.1) only fixes bugs, and anything that would break a follower app's setup, your settings or your stored readings waits for a new major version. When the settings or the readings database change shape, the app converts what you have on update.

Pull requests don't change the version. Each adds its changelog line under `## [Unreleased]`, and the version is picked when a release is cut: minor if that block has a feature, patch if it only has fixes.

Every build also has a build number (the number in brackets in About, as in 1.0.0 (5)). It goes up with every build that is shipped and never resets, because installed copies only update to a higher build. A published version or tag is never reused or moved; a broken release is fixed by the next patch release.

## Cutting a release

For maintainers. Releases are signed with a Developer ID certificate, notarized by Apple, and described in a signed appcast that installed copies check for updates.

1. Add the dated `## [X.Y.Z] - YYYY-MM-DD` section to `CHANGELOG.md` and commit it. That section becomes the release notes people see in the update window.
2. Run `DEVELOPMENT_TEAM=<team> CGMRELAY_NOTARY_PROFILE=<profile> macos/scripts/release.sh X.Y.Z BUILD`, with a build number above the last release's. It builds, signs and notarizes the DMG and writes it, `appcast.xml` and `RELEASE.md` to `macos/.build/release/X.Y.Z/`. Nothing is published yet.
3. Run `macos/scripts/publish-release.sh X.Y.Z` to tag and publish it. It shows the plan and asks you to type the version, and it can be run again after a partial failure.
4. Run `macos/scripts/verify-release.sh X.Y.Z` to check the live release the way an installed copy sees it.

## License

By contributing, you agree that your contribution is licensed under the [GNU Affero General Public License v3.0](LICENSE), the same license as the rest of the project.
