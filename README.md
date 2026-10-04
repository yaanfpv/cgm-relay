# CGM Relay

**Every minute of your FreeStyle Libre glucose, kept, even while your phone sleeps.**

CGM Relay is a small Mac menu bar app that follows your LibreLinkUp account every minute, keeps each reading encrypted on your Mac, and hands them to xDrip4iOS, xDrip+, LoopFollow, Nightguard or any Nightscout follower app, so the gaps your phone leaves overnight fill themselves in.

**[Download for Mac](https://github.com/yaanfpv/cgm-relay/releases/latest)** · [Supported apps](#supported) · [Run it on a server](docs/TECHNICAL.md#run-it-on-a-server) · [How it works](docs/TECHNICAL.md)

Free and open source · macOS 15 or later · No account, no cloud of ours

**Please read this first.** CGM Relay is not a medical device. Readings and alerts can arrive late, go missing or be wrong. Don't make treatment decisions from it, and keep the official Libre app and its alarms on for lows. It isn't made by or affiliated with Abbott, and it comes with no warranty.

**Privacy.** CGM Relay collects nothing. It sends your readings only to your own follower apps.

![The CGM Relay menu open under the menu bar icon, showing a reading of 100 mg/dL, Current, just now, with Stop, Settings and Quit buttons](docs/images/panel.png)

## Your phone forgets. CGM Relay doesn't.

Apps like xDrip4iOS only get a reading when your phone lets them run, and phones are stingy about that, especially at night. LibreLinkUp keeps history only every 15 minutes, so every minute nobody asked for is gone for good. CGM Relay asks every minute from a Mac that stays awake, keeps every reading, and your app catches up on all of them the moment it wakes.

## Set up in two minutes

The first time it opens, CGM Relay walks you through setup: sign in with your LibreLinkUp account, choose how your phone reaches your Mac, connect your app with a QR code, and turn on Open at Login. With Tailscale, one click gives your phone a private HTTPS address that works at home and away.

## Quiet until something needs you

The menu bar icon stays monochrome while readings are fresh, and turns amber when they are late or red when something stops. Open it for the latest reading, when it arrived, and whether your app is keeping up. Turn on "Show the reading in the menu bar" if you want the number there all the time.

## Your data stays yours

Readings are stored encrypted on your Mac, and only apps holding your access token can read them. Nothing is reachable from outside until you choose how, and there are no accounts, analytics or cloud of ours in between.

## Get started

1. [Download CGM Relay](https://github.com/yaanfpv/cgm-relay/releases/latest), open the disk image and drag CGM Relay to Applications.
2. Follow the setup steps, and turn on Open at Login at the end so it survives a restart.
3. Point your app at the address and token setup shows you (details for each app are below).

Only one thing should follow your LibreLinkUp account. Once your app reads from CGM Relay, switch its LibreLinkUp follower off.

## Connect your app

**xDrip4iOS.** In Settings, set **Master or Follower** to **Follower** and **Data Source** to **Nightscout**. Then under **Sharing and Services**, open **Nightscout** and fill in **URL** with the relay's address and **Token** with your access token. If the address has a port (`http://192.168.1.5:1337`), the URL takes it without the port and the port goes in **Port**. Leave **API_SECRET** blank.

**xDrip+ (Android).** In Settings, choose **Nightscout Follower** as the hardware data source. It has one field, **Nightscout Follow URL**, and the token goes in front of the host in the address: `https://YOUR-TOKEN@your-relay-address`.

**LoopFollow.** In Settings, open **Nightscout**. Put the relay's address in **URL** and your access token in **Token**.

**Nightguard.** Put the relay's address in **Nightscout URL**, with no slash at the end, and your access token in **API Token**. Nightguard asks for both the first time it opens.

## Features

- **Every minute, kept.** A reading a minute from LibreLinkUp, with its 15-minute history filling any gap after a restart.
- **Works with Nightscout follower apps.** xDrip4iOS, xDrip+, LoopFollow, Nightguard, and anything that reads a Nightscout site.
- **Encrypted at rest.** Glucose values are encrypted on disk; a copied disk or backup shows timestamps only.
- **One-click Tailscale HTTPS.** A private address your phone reaches anywhere, with no port forwarding.
- **Calm menu bar.** Monochrome when all is well, colour only when something needs you, and a right-click menu for Settings and bug reports.
- **Opens at login** and recovers on its own from LibreLinkUp rate limits and outages.
- **Keeps what you choose.** 15 days by default, adjustable.
- **Works without a mouse.** The menu bar item opens from the keyboard and VoiceOver.

## Supported

- macOS 15 Sequoia or later, on Apple silicon and Intel.
- FreeStyle Libre sensors that share through LibreLinkUp.
- xDrip4iOS, xDrip+, LoopFollow and Nightguard as follower apps. Each was tested against CGM Relay with the settings above, and xDrip4iOS is the one the author uses day to day.
- A Linux server instead of a Mac: see [Run it on a server](docs/TECHNICAL.md#run-it-on-a-server).

## Privacy

CGM Relay talks to LibreLinkUp, with your own account, to fetch your readings, and once a day to GitHub to check for a newer version. That update check carries the app's name and version and your internet address, and nothing about you, your account or your readings; turn it off in Settings > Updates. Your follower apps talk to your Mac, not to us. The Tailscale step runs Tailscale's own command on your Mac only when you click it. Report a Bug opens a GitHub page in your browser with only the app version and build, your macOS version and your chip filled in, and nothing is sent unless you submit it.

## Good to know

- LibreLinkUp has no official public API. CGM Relay uses the same endpoints the LibreLinkUp app and other open-source followers use, and those can change.
- It sees only what LibreLinkUp has: if the phone running LibreLink loses its connection, those minutes arrive later as 15-minute history.
- It needs a Mac that stays awake, or a small server.
- It is not a medical device, and its readings and alerts can be late, missing or wrong: see the note at the top.

## Contributing

Bug reports and ideas are welcome: use Report a Bug in the app, or [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new). For anything larger, open an issue first so we can talk it through. [CONTRIBUTING.md](CONTRIBUTING.md) covers building it and running the tests, and [SECURITY.md](SECURITY.md) covers reporting a vulnerability.

## License

CGM Relay is free and open source under the [GNU Affero General Public License v3.0](LICENSE): you can use it, change it and share it, and if you distribute a changed version or run one for other people, you publish your changes under the same license. Companies that want to build it into a closed product can ask about a commercial license by [opening an issue](https://github.com/yaanfpv/cgm-relay/issues/new) or reaching [@YaanFPV](https://github.com/YaanFPV).

Built by [@YaanFPV](https://github.com/YaanFPV).
