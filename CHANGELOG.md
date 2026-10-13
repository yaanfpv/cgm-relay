# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

- Pick how your phone reaches your Mac at any time, in setup and in Settings: Tailscale HTTPS is one of the ways beside your tailnet and your local network, nothing is greyed out because Tailscale HTTPS is on, and switching away leaves it set up in Tailscale. Turning Tailscale HTTPS off is a separate action that never changes your choice, and CGM Relay never turns it on for you.
- The phone HTTPS setup now asks which phone you have, drops the Tailscale prompt, and lists the steps an iPhone actually shows.
- A port another app holds is now refused as soon as it is typed, whichever address that app listens on, and a saved port change says follower apps need the new address.

## [1.0.0] - 2026-10-11

### Added

- A Mac menu bar app that checks your LibreLinkUp account about once a minute and keeps every reading it fetches, so a follower app on your phone catches up when it opens, even after a night asleep. A minute it didn't fetch, for example while your Mac was off or your phone was offline, is covered only by LibreLinkUp's own history of one reading every 15 minutes.
- Works with xDrip4iOS, xDrip+, LoopFollow, Nightguard and any app that follows a Nightscout site: CGM Relay serves the part of the Nightscout API those apps use, accepts every token form they send, and compresses large responses for apps that ask.
- First-launch setup: a short safety notice, then sign in to LibreLinkUp (checked before anything is saved, with a plain reason when a check fails), choose how your phone reaches your Mac, connect your app, and turn on Open at Login. Setup finishes only once a phone can actually reach the Mac, and moves to a free port when the default is taken.
- Connect your app without typing the token: pick your app and scan its QR code. xDrip+ and LoopFollow import their settings straight from it; xDrip4iOS and Nightguard open a short-lived page served by the relay with each value and its own Copy button, and the token is never in the code. The steps follow each app's own settings screen, in the order it asks.
- One-click Tailscale HTTPS: a private address your phone reaches at home and away, with no port forwarding. It takes port 443, or the nearest free port above it when something else on your tailnet already serves 443.
- HTTPS on your home Wi-Fi without a public certificate: CGM Relay keeps its own small certificate authority for your Mac's `.local` name and private network addresses, and a guided sheet hands each phone its certificate once by scanning a code. Every address it gives a follower app on your local network is https, so readings never cross your Wi-Fi in plaintext.
- A calm menu bar icon that stays monochrome while readings are current, turns amber when one is late and red when something stops, and shows the latest reading and its trend beside it unless you turn that off. The menu shows the reading, how fresh it is, and whether your app is keeping up.
- Button labels that read clearly in Light and Dark, including in a window behind another app: white on a deeper teal in Light, and a readable grey when the window is in the background or the button isn't available yet.
- Readings encrypted on your Mac (AES-256-GCM, key in your Keychain), kept 30 days by default and adjustable from 1 to 90; lowering the number asks before anything is deleted. The relay's local status port needs a secret the app and its relay share, so another program on the Mac cannot read your follower token through it.
- Optional alerts when no new reading arrives for a while and when sign-in is failing, with a plain note that alerts can be late or missed and don't replace the official app's alarms.
- In-app updates from GitHub: a quiet daily check, a signed download, and an install the next time you quit, with What's New in Settings and About. Turn the check off in Settings > Updates.
- Settings for your account, connecting apps, units (mg/dL or mmol/L), retention, port and who can reach the relay, alerts, updates, and an About page with Copy Diagnostics, Report a Bug and Suggest a Feature.
- The menu opens from the keyboard and from VoiceOver as well as a click, and the right-click menu offers Settings, Report a Bug and Quit.
- Run it on a Linux server instead of a Mac: a single `cgm-relay` program with `setup` and `serve`, configured by a file or environment variables, with a loopback-only status page.
- A disk image that opens to a window showing where to drag CGM Relay.
- If the saved readings can't be opened (after a Keychain reset, a restored backup or a move to a new Mac), the menu says what happened and offers Start Fresh, which moves the old file aside rather than deleting it. A second copy opened by mistake says the first one is running and offers to try again once it quits.
- Its own app icon.
- The engine's log names each skipped stretch with how many checks saw the earlier reading in between, how many failed, and the longest time between checks, so a gap can be traced to the phone's uploads or to the relay's timing.
- For contributors: a fake LibreLinkUp server (`go run ./cmd/llufake`) and development launch arguments, so the engine and the app run end to end without a real account and never touch an installed copy.
- For contributors: pull request checks for Go formatting, vet, tests and build, Swift tests, the Mac app build and the changelog entry, each naming the failing file and line where there is one and the command to run it, one final `gate` check that passes only when the build and test checks have, and the changelog entry as a check of its own.
- For maintainers: release tooling that builds, signs, notarizes, publishes and verifies a release.
