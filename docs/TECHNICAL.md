# How CGM Relay works

The README covers what CGM Relay does and how to set it up. This page is the detail behind it: how it reads LibreLinkUp, how readings are stored, what it serves, and how to run it on a server instead of a Mac.

## Reading LibreLinkUp

CGM Relay signs in to your LibreLinkUp follower account and asks for the latest reading once a minute. LibreLinkUp's own history, 15-minute points going back about 12 hours, fills any gap after a restart or an outage. If LibreLinkUp rate-limits it, it backs off and recovers on its own. If sign-in fails, it says so in the menu bar (or on the local status page on a server) and keeps retrying at a gentle pace.

## Storage and encryption

Readings go into a small SQLite database on disk. Each value and trend is encrypted with AES-256-GCM, and the key is kept apart from the data (in the Keychain on a Mac, in its own file on a server), so a copied disk, a backup or a stolen database file shows timestamps but no glucose values. Encryption cannot protect you from someone who can already use your account on that machine, because they can reach the key too. Every commit is synced to disk in full, so a power cut never loses a reading that was already stored. Readings older than the retention you choose (15 days by default) are deleted.

## What it serves

CGM Relay serves the part of the Nightscout API that follower apps use: `entries.json`, `entries/sgv.json` and `entries/current.json` with `count` and date filtering, `status.json` (the one endpoint that answers without a token, and only with whether the relay is up, its clock and its unit), and the checks xDrip4iOS, LoopFollow and Nightguard make during setup (`treatments`, `devicestatus`, `profile`, answered empty). Every other request needs your access token, either as `?token=` or as the `api-secret` header these apps already send (raw or SHA-1, as Nightscout accepts). Responses of 1 KB or more are gzip-compressed when the app asks for it; smaller ones, like a single reading or the status, are sent plain.

## Reaching it from your phone

By default the relay listens only on the machine it runs on, so something has to carry your phone's requests to it, or you choose to let your local network reach it:

- **Tailscale HTTPS** (the Mac app does this in one click): `tailscale serve --bg --https=443 http://127.0.0.1:1337` gives your Mac a private HTTPS address on your tailnet that your phone reaches at home and away. If 443 is taken, the app uses 8443 or 10000.
- **Your local network**: the relay listens on your Mac's network address, unencrypted, for a phone on the same Wi-Fi.
- **A reverse proxy with a certificate, or a tunnel**, on a server.

## Run it on a server

CGM Relay is built from source. You need Go (the version in `go.mod`). One command installs the engine:

```bash
go install github.com/yaanfpv/cgm-relay/cmd/cgm-relay@latest
```

Or clone the repository and build it:

```bash
git clone https://github.com/yaanfpv/cgm-relay.git
cd cgm-relay
go build ./cmd/cgm-relay
```

That leaves a `cgm-relay` program in the current folder; the commands below call it by name, so put it somewhere on your `PATH` (or run it as `./cgm-relay`).

Set it up once. It asks for your LibreLinkUp email and password, generates an access token and an encryption key, and writes both files readable only by you:

```bash
cgm-relay setup
```

Then run it:

```bash
cgm-relay serve
```

It listens on `127.0.0.1:1337` by default, so nothing outside the machine can reach it until you choose to expose it. Every setting can also come from the environment, which suits a container:

| Variable | What it sets |
| --- | --- |
| `CGM_RELAY_EMAIL` | LibreLinkUp account email |
| `CGM_RELAY_PASSWORD` | LibreLinkUp account password |
| `CGM_RELAY_TOKEN` | the access token your follower apps use |
| `CGM_RELAY_LISTEN_ADDR` | where the Nightscout API listens |
| `CGM_RELAY_STATUS_ADDR` | where the local status page listens (always loopback) |
| `CGM_RELAY_DATABASE_PATH` | where readings are stored |
| `CGM_RELAY_KEY_PATH` or `CGM_RELAY_KEY` | the encryption key file, or the key itself |
| `CGM_RELAY_RETENTION_DAYS` | how many days of readings to keep (default 15) |

The local status page answers only on the machine itself and refuses requests carrying any other host name. Passwords, tokens and keys never appear in logs or error messages.

## Building from source

You need Go (the version in `go.mod`) for the engine, and Xcode 27 or later with XcodeGen for the Mac app. `go build ./cmd/cgm-relay` builds the engine on its own; `bash macos/scripts/build.sh CODE_SIGNING_ALLOWED=NO` builds the app with the engine embedded, for Apple silicon and Intel. [CONTRIBUTING.md](../CONTRIBUTING.md) has the tests, the fake LibreLinkUp server, and the launch arguments for running a development build next to your real one.
