# Security

## Reporting a vulnerability

Please report it privately, not in a public issue. On this repo's [Security tab](https://github.com/yaanfpv/cgm-relay/security), choose **Report a vulnerability**. Only I can read it, and we can sort out a fix before anything is public.

Tell me what you found, how to reproduce it, and the version and build (both are in About). Never include a real LibreLinkUp password, access token or anyone's readings; made-up values are fine.

## What counts

The Mac app (menu, Settings, setup, updater) and the relay itself, on a Mac or a server. Things I especially want to hear about:

- reading someone's data without the access token
- opening the database without its key
- making the relay connect somewhere it shouldn't
- getting the updater to install anything but a signed release

Problems in LibreLinkUp, Tailscale or a follower app belong with their makers.

A wrong or missing reading is a normal bug, so [open an issue](https://github.com/yaanfpv/cgm-relay/issues/new) for that.
