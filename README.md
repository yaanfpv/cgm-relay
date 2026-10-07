# CGM Relay

**Every minute of your FreeStyle Libre glucose, kept, even while your phone sleeps.**

CGM Relay is a small Mac menu bar app that follows your LibreLinkUp account every minute, keeps each reading encrypted on your Mac, and hands them to xDrip4iOS, xDrip+, LoopFollow, Nightguard or any Nightscout follower app, so the gaps your phone leaves overnight fill themselves in.

**[Download for Mac](https://github.com/yaanfpv/cgm-relay/releases/latest)** · [Supported apps](#supported) · [Run it on a server](docs/TECHNICAL.md#run-it-on-a-server) · [How it works](docs/TECHNICAL.md)

Free and open source · macOS 15 or later · No account, no cloud of ours

**Please read this first.** CGM Relay is not a medical device. Readings and alerts can arrive late, go missing or be wrong. Don't make treatment decisions from it, and keep the official Libre app and its alarms on for lows. It isn't made by or affiliated with Abbott, and it comes with no warranty.

![The CGM Relay menu open under the menu bar icon, showing a reading of 100 mg/dL, Current, just now, with Stop, Settings and Quit buttons](docs/images/panel.png)

## Your phone forgets. CGM Relay doesn't.

Apps like xDrip4iOS only get a reading when your phone lets them run, and phones are stingy about that, especially at night. LibreLinkUp keeps history only every 15 minutes, so every minute nobody asked for is gone for good. CGM Relay asks every minute from a Mac that stays awake, keeps every reading, and your app catches up on all of them the moment it wakes.

## Get started

1. [Download CGM Relay](https://github.com/yaanfpv/cgm-relay/releases/latest), open the disk image and drag CGM Relay to Applications.
2. Follow setup: sign in to LibreLinkUp, choose how your phone reaches your Mac (with Tailscale, one click gives it a private HTTPS address that works at home and away), connect your app with a QR code, and turn on Open at Login.
3. Once your app reads from CGM Relay, switch its own LibreLinkUp follower off. Only one thing should follow your account.

## Connect your app

**xDrip4iOS.** In Settings, set **Master or Follower** to **Follower** and **Data Source** to **Nightscout**. Then under **Sharing and Services**, open **Nightscout** and fill in **URL** with the relay's address and **Token** with your access token. If the address has a port (`http://192.168.1.5:1337`), the URL takes it without the port and the port goes in **Port**. Leave **API_SECRET** blank.

**xDrip+ (Android).** In Settings, choose **Nightscout Follower** as the hardware data source, and put `https://YOUR-TOKEN@your-relay-address` in **Nightscout Follow URL**.

**LoopFollow.** In Settings, open **Nightscout**. Put the relay's address in **URL** and your access token in **Token**.

**Nightguard.** Put the relay's address in **Nightscout URL**, with no slash at the end, and your access token in **API Token**.

## Features

- **Every minute, kept,** with LibreLinkUp's 15-minute history filling any gap after a restart.
- **Encrypted at rest.** A copied disk or backup shows timestamps but no glucose values. Readings are kept 15 days by default, adjustable.
- **Calm menu bar.** Monochrome while readings are fresh, amber when late, red when something stops; the reading can sit in the menu bar too.
- **Opens at login** and recovers on its own from LibreLinkUp rate limits and outages.
- **Works without a mouse.** The menu opens from the keyboard and VoiceOver.

## Supported

- macOS 15 Sequoia or later, on Apple silicon and Intel.
- FreeStyle Libre sensors that share through LibreLinkUp.
- xDrip4iOS, xDrip+, LoopFollow and Nightguard, each tested with the settings above, and anything that reads a Nightscout site.
- A Linux server instead of a Mac: see [Run it on a server](docs/TECHNICAL.md#run-it-on-a-server).

## Privacy

CGM Relay collects nothing. It talks to LibreLinkUp with your own account, and once a day to GitHub to check for a newer version (that check carries the app's name and version, and you can turn it off in Settings > Updates). Your follower apps talk to your Mac, not to us. Report a Bug fills in only your app version, macOS version and chip, and sends nothing unless you submit it.

## Good to know

- LibreLinkUp has no official public API. CGM Relay uses the same endpoints the LibreLinkUp app and other open-source followers use, and those can change.
- It sees only what LibreLinkUp has: if the phone running LibreLink loses its connection, those minutes arrive later as 15-minute history.
- It needs a Mac that stays awake, or a small server.

## Contributing

Use Report a Bug in the app or [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new). [CONTRIBUTING.md](CONTRIBUTING.md) covers building and testing, and [SECURITY.md](SECURITY.md) covers reporting a vulnerability.

## License

[GNU Affero General Public License v3.0](LICENSE). For a commercial license to build it into a closed product, [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new) or reach [@YaanFPV](https://github.com/YaanFPV).

Built by [@YaanFPV](https://github.com/YaanFPV).
