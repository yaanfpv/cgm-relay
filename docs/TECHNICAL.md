# How CGM Relay works

## Reading LibreLinkUp

CGM Relay signs in to your LibreLinkUp follower account and fetches the latest reading about once a minute. After each new reading it asks again a little before the next one is due, then every 15 seconds until it arrives. A reading that LibreLinkUp replaces quickly can still fall between two checks and be missed. After a restart or an outage, LibreLinkUp's own history, which has a point every 15 minutes, fills the gap at that spacing. Rate limits and sign-in failures back off and retry on their own, and the menu bar says when sign-in is failing.

## Storage

Readings live in a small SQLite database. Each glucose value and trend is encrypted with AES-256-GCM. The file alone shows when each reading was taken and where it came from, not what it said. On a Mac the key is in your Keychain. On a server it is a file next to the database, so a backup that holds both is not protected. Readings older than your retention setting (30 days by default in the Mac app, 15 on a server) are deleted.

## Settings

The Mac app keeps its settings in its macOS preferences. If macOS hands back nothing when the app opens, the app reads its own preferences file instead. No file, or a file without the app's settings, is treated as a fresh install, and setup runs. Settings found in the file are used, and changes stay off until the next launch. If the file cannot be read, or its settings cannot be decoded, the app says so, offers Quit and does not start the relay, so it never sets itself up again over settings it could not read.

## What it serves

The part of the Nightscout API follower apps use:

- `entries.json`, `entries/sgv.json` and `entries/current.json`, with `count` and date filters.
- `status.json`, and `experiments/test`, which apps use to check a token.
- Empty answers for `treatments`, `devicestatus`, `profile` and `/api/v2/properties`, because some apps ask for them during setup. The properties route answers `iob` and `cob` as empty objects, since the relay has no insulin or carbs.

Everything needs your access token, as `?token=` or the `api-secret` header (raw or SHA-1, like Nightscout), except these:

- `status.json` answers without a token. It says only that the relay is up, its clock and its unit. A wrong token, in any of those forms or as a Bearer token, gets a 401, so an app's connection check catches a typo.
- The plain page at `/` shows nothing about you.
- The page a setup QR code opens needs its own code, which lasts 10 minutes. That page shows the access token, so treat the QR code like the token while it is on screen.

So the token protects every reading. Large responses are gzipped for apps that ask.

## Reaching it from your phone

The relay listens only on the machine it runs on until you choose a way in. The Mac app offers the ways below, and the default is This Mac only.

- **Your own Tailscale: Tailscale HTTPS.** The Mac app sets this up in one click. It runs `tailscale serve --bg --https=443 http://127.0.0.1:1337`, which gives your Mac a private https address your phone can reach anywhere it has Tailscale. If something else already serves 443 on your tailnet, it takes the nearest free port above it.
- **Your own Tailscale: My tailnet.** Any device on your tailnet can connect.
- **This Mac only.** Only apps on this Mac connect.

On a server, put a reverse proxy or a tunnel in front.

### The built-in Tailscale route

Instead of your own Tailscale, the app can run a Tailscale node of its own. Setup asks which to use when Tailscale is installed. When it is not, setup offers the built-in route.

- **Sign-in.** You sign in to Tailscale once, in a window the app opens. A free account works, since [Funnel is available on all plans](https://tailscale.com/docs/features/tailscale-funnel).
- **A public address.** The node turns on Tailscale Funnel and serves a public https address, so a phone needs nothing installed and apps that fetch from their own servers can reach it. A new name can take up to 10 minutes to appear, and the app says so while it waits.
- **What carries the traffic.** There is no account or server of ours in the path. Funnel's relay servers [do not decrypt the traffic](https://tailscale.com/docs/features/tailscale-funnel) between public devices and your Mac.
- **What the token protects.** Only the paths a follower app or the pairing page uses are answered. Every other path gets a 404. Readings need the token. The paths that answer without a token are the ones listed above. One sender can hold at most 8 connections open, and the address at most 128 in all, so one sender cannot fill it.
- **The name is public.** The app asks Tailscale to name the node `cgm-relay`, and Tailscale assigns the name the address uses. It can differ, for example `cgm-relay-1` when another machine on your tailnet already has the name, or a name you set in Tailscale. The address is that assigned name followed by your tailnet's DNS name. Tailscale issues the address's certificate, and [certificates are recorded in public certificate logs](https://tailscale.com/docs/how-to/set-up-https-certificates), so that name is public.
- **Ready means answering.** The app tests the address from the internet every two minutes while it is healthy. After a failed test it tests again sooner, waiting longer each time up to five minutes. Ready shows only while a test has passed within the last six. It says the address is not answering once there have been at least three failed tests in a row and the failures have lasted at least four minutes. Then it repairs itself and offers Try Again. How soon it notices therefore varies. With no internet on the Mac it says it is waiting.
- **What stays on the Mac.** The node's sign-in lives in a folder beside the database, readable only by you and left out of Time Machine backups. The node's own logs are not uploaded to Tailscale.

### Key expiry

A node's sign-in expires. Tailscale's default is [180 days](https://tailscale.com/docs/features/access-control/key-expiry), and the admin of the tailnet sets it. The app reads the expiry from Tailscale and warns 14 days ahead, with a Sign In Again button. It never turns expiry off. Once the key expires, connections to the Mac stop until you sign in again.

### Leaving the route

Choosing your own Tailscale or This Mac only logs the node out and removes its state folder. Tailscale keeps a logged-out machine in your account, marked expired, until you remove it in the [admin console](https://login.tailscale.com/admin/machines). If the logout cannot reach Tailscale, for example while the Mac is offline, the app keeps the folder and tries again the next time it opens, and Settings says the Mac is not yet logged out. Until a logout goes through, the machine stays in your account as it was.

Sign Out of LibreLinkUp does only that. The node and the address stay, so after you sign in again your apps need no change.

## Keeping the Mac awake

On a desktop Mac the app only holds an idle-sleep assertion while the relay runs, and installs nothing. On a laptop, staying awake with the lid closed needs the root-only `pmset` setting `disablesleep`. Setup installs a rule file and a boot job with one administrator prompt. The rule lets your user run the two `pmset` commands that switch the setting on and off without a password, and nothing else. The app also asks you to approve a background item once under System Settings > General > Login Items. That item is the helper below.

- The sleep setting is on only while you chose keep-awake, the relay is running and the Mac is on power. The lid-closed part applies to laptops only. On battery the Mac sleeps as usual.
- The app turns the setting off when the relay stops, and a boot job turns it off at every restart.
- If CGM Relay ends unexpectedly, the approved helper looks every 20 seconds and turns the setting off while the app is not running. A change of power source makes it look at once.
- Turning keep-awake off keeps the permission, so turning it on again never asks again.

### What keep-awake leaves on your Mac

These exist only on a laptop where you turned keep-awake on. Nothing removes them when you delete the app. To clear them after deleting it, open Terminal and run:

```bash
sudo pmset -a disablesleep 0
sudo launchctl bootout system/com.yaanfpv.cgmrelay.sleep-reset
sudo rm /Library/LaunchDaemons/com.yaanfpv.cgmrelay.sleep-reset.plist
sudo rm /etc/sudoers.d/cgm-relay-disablesleep
```

The first line only matters if the app ended while the setting was on. The second may report an error if the job is not loaded, which is fine. The background item is listed under System Settings > General > Login Items. Switch it off there before you delete the app.

## Updates

CGM Relay uses Sparkle. It checks the releases page on GitHub once a day, downloads an update in the background and installs it the next time the app quits. Restart to Update installs it now. The app never restarts by itself. Settings > Updates turns the check and the download off.

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
| `CGM_RELAY_LIBRELINKUP_BASE_URL` | a different address for LibreLinkUp sign-in and fetches, for testing against a stand-in |

The status page reports whether the relay is fetching and which apps are reading from it. On a server it is open on loopback. When the Mac app runs the relay, it needs a secret only the app has. Passwords, tokens and keys never show up in logs.

To build the Mac app or run the tests, see [CONTRIBUTING.md](../CONTRIBUTING.md).
