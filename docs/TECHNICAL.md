# How CGM Relay works

## Reading LibreLinkUp

CGM Relay signs in to your LibreLinkUp follower account and fetches the latest reading about once a minute, timed so it lands just after your phone uploads one. After a restart or an outage, LibreLinkUp's own history (a point every 15 minutes, about 12 hours back) fills the gap. Rate limits and sign-in failures back off and retry on their own, and the menu bar says when sign-in is failing.

## Storage

Readings live in a small SQLite database. Each glucose value and trend is encrypted with AES-256-GCM, so the database file alone shows timestamps and nothing else. On a Mac the key is in your Keychain. On a server it's a file next to the database, so a backup that holds both isn't protected. Readings older than your retention setting (15 days by default) are deleted.

## What it serves

The part of the Nightscout API follower apps use: `entries.json`, `entries/sgv.json` and `entries/current.json` with `count` and date filters, `status.json`, and empty answers for `treatments`, `devicestatus` and `profile`, because some apps check for them during setup.

Everything needs your access token, as `?token=` or the `api-secret` header (raw or SHA-1, like Nightscout), except `status.json`, which only says the relay is up, its clock and its unit. The plain page at `/` and the page a setup QR code opens (it carries its own short-lived code) need no token either. Large responses are gzipped for apps that ask.

## Reaching it from your phone

The relay only listens on the machine it runs on until you choose a way in:

- **Tailscale HTTPS.** The Mac app sets this up in one click. It runs `tailscale serve --bg --https=443 http://127.0.0.1:1337`, which gives your Mac a private HTTPS address your phone can reach anywhere. If 443 is taken it uses 8443 or 10000.
- **Your local network.** Plain HTTP on your Mac's network address, for a phone on the same Wi-Fi.
- **A reverse proxy or a tunnel,** on a server.

## Run it on a server

You need Go (the version in `go.mod`). Install the relay with `go install github.com/yaanfpv/cgm-relay/cmd/cgm-relay@latest`, which puts `cgm-relay` in Go's `bin` folder (`$(go env GOPATH)/bin`), so make sure that folder is on your `PATH`. Or build it from a clone with `go build ./cmd/cgm-relay`, which leaves it in the current folder, and run it as `./cgm-relay` below. Then run setup once. It asks for your LibreLinkUp email and password and writes a config file and an encryption key, both readable only by you:

```bash
cgm-relay setup
cgm-relay serve
```

It listens on `127.0.0.1:1337`, so nothing outside the machine reaches it until you expose it. Every setting can also come from the environment, which suits a container:

| Variable | What it sets |
| --- | --- |
| `CGM_RELAY_EMAIL` | LibreLinkUp email |
| `CGM_RELAY_PASSWORD` | LibreLinkUp password |
| `CGM_RELAY_TOKEN` | the access token your apps use |
| `CGM_RELAY_LISTEN_ADDR` | where the Nightscout API listens |
| `CGM_RELAY_STATUS_ADDR` | where the status page listens (always loopback) |
| `CGM_RELAY_DATABASE_PATH` | where readings are stored |
| `CGM_RELAY_KEY_PATH` or `CGM_RELAY_KEY` | the key file, or the key itself |
| `CGM_RELAY_RETENTION_DAYS` | days of readings to keep (default 15) |

The status page reports whether the relay is fetching and which apps are reading from it. On a server it's open on loopback; when the Mac app runs the relay, it needs a secret only the app has. Passwords, tokens and keys never show up in logs.

To build the Mac app or run the tests, see [CONTRIBUTING.md](../CONTRIBUTING.md).
