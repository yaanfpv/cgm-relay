# Security

## Reporting a vulnerability

Please report a vulnerability privately, not in a public issue. On the [Security tab](https://github.com/yaanfpv/cgm-relay/security) of this repository, choose **Report a vulnerability**. That opens a private report only the maintainer can read, and we can work out a fix there before anything is public.

Say what you found, how to reproduce it, and which version or build of CGM Relay it affects (About shows both). Please never include a real LibreLinkUp password, access token or someone's readings; made-up values are enough.

## What is in scope

- The Mac app: its menu bar panel, Settings, setup and updater.
- The relay itself: the Go program that follows LibreLinkUp, stores readings and serves the Nightscout API, on a Mac or a server.

Things like a way to read readings without the access token, to read the stored database without its key, to make the relay reach somewhere it should not, or to get the updater to install something that is not a signed release are exactly what we want to hear about.

Weaknesses in LibreLinkUp, Tailscale or a follower app belong with their own makers.

## Not a medical device

CGM Relay is not a medical device. Readings and alerts can be late, missing or wrong, and nothing here should be used for treatment decisions. A wrong or missing reading is a bug worth an ordinary [issue](https://github.com/yaanfpv/cgm-relay/issues/new); a way for someone else to see or change your data is a vulnerability, so report it privately as above.
