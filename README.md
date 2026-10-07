# CGM Relay

**Every minute of your FreeStyle Libre glucose, kept, even while your phone sleeps.**

CGM Relay is a small Mac menu bar app. It follows your LibreLinkUp account every minute and hands every reading to xDrip4iOS, xDrip+, LoopFollow, Nightguard or any other Nightscout follower app, so the gaps your phone leaves overnight fill themselves in.

**[Download for Mac](https://github.com/yaanfpv/cgm-relay/releases/latest)** · [Supported apps](#supported) · [Run it on a server](docs/TECHNICAL.md#run-it-on-a-server) · [How it works](docs/TECHNICAL.md)

Free and open source · macOS 15 or later · No account, no cloud of ours

**Please read this first.** CGM Relay is not a medical device. Readings and alerts can be late, missing or wrong. Don't make treatment decisions from it, and keep the official Libre app and its alarms on for lows. It isn't made by or affiliated with Abbott, and it comes with no warranty.

![The CGM Relay menu open under the menu bar icon, showing a reading of 100 mg/dL, Current, just now, with Stop, Settings and Quit buttons](docs/images/panel.png)

## Your phone forgets. CGM Relay doesn't.

Follower apps only get a reading when your phone lets them run, and phones are stingy about that, especially at night. LibreLinkUp only keeps a point every 15 minutes, so any minute nobody fetched is gone for good. CGM Relay fetches every minute from a Mac that stays awake, and your app catches up on all of it the moment it wakes.

## Get started

1. [Download CGM Relay](https://github.com/yaanfpv/cgm-relay/releases/latest), open the disk image and drag it to Applications.
2. Open it and follow setup. It signs you in to LibreLinkUp, sets up how your phone reaches your Mac (one click if you use Tailscale) and connects your app with a QR code.
3. Turn off your app's own LibreLinkUp follower. Only one thing should follow your account.

## Connect your app

Setup shows a QR code for each of these. To set one up by hand:

**xDrip4iOS.** In Settings, set **Master or Follower** to **Follower** and **Data Source** to **Nightscout**. Under **Sharing and Services**, open **Nightscout**, put the relay's address in **URL** and your access token in **Token**. If the address has a port, like `:1337`, put that in **Port** and leave it out of **URL**. Leave **API_SECRET** blank.

**xDrip+ (Android).** In Settings, choose **Nightscout Follower** as the data source and set **Nightscout Follow URL** to `https://YOUR-TOKEN@your-relay-address`.

**LoopFollow.** In Settings, open **Nightscout** and fill in **URL** and **Token**.

**Nightguard.** Put the address in **Nightscout URL**, with no slash at the end, and the token in **API Token**.

## Features

- Readings are encrypted on your Mac and kept for 15 days, or as long as you like.
- The menu bar icon turns amber when readings are late and red when something stops, and can show the number too.
- It can open at login, and it recovers by itself after a LibreLinkUp outage or rate limit.
- Keyboard and VoiceOver work.

## Supported

- macOS 15 Sequoia or later, Apple silicon and Intel.
- FreeStyle Libre sensors that share through LibreLinkUp.
- xDrip4iOS, xDrip+, LoopFollow, Nightguard, and anything that reads a Nightscout site.
- Linux, if you'd rather [run it on a server](docs/TECHNICAL.md#run-it-on-a-server).

## Privacy

CGM Relay collects nothing. It talks to LibreLinkUp with your own account, and to GitHub once a day to check for updates, which you can turn off in Settings > Updates. Your follower apps talk to your Mac, not to us. Report a Bug opens a prefilled GitHub issue, and nothing is sent until you submit it.

## Good to know

- LibreLinkUp has no official API. CGM Relay uses the same endpoints the LibreLinkUp app and other open-source followers use, and those can change.
- It only sees what LibreLinkUp has. If the phone running LibreLink drops off, those minutes come back later as 15-minute history.

## Contributing

Use Report a Bug in the app (right-click the menu bar icon) or [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new). [CONTRIBUTING.md](CONTRIBUTING.md) covers building and testing, and [SECURITY.md](SECURITY.md) covers reporting a vulnerability.

## License

[GNU AGPL-3.0](LICENSE). If you want to build it into a closed product, [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new) and ask about a commercial license.

Built by [@YaanFPV](https://github.com/YaanFPV).
