# Security

## What this software exposes

`fake-teams` listens on `127.0.0.1:8124` only (never on a network interface) and has **no authentication**. Any process
running on the same machine can connect as "Dell Optimizer", post a fake meeting state (`POST /bridge/state`) or read
and consume the queued touchpad commands (`GET /bridge/commands`). The pairing token is not a secret. On a single-user
machine this is an accepted trade-off; do not install it on a shared computer.

`telemost-bridge` uses UI Automation to click a few Telemost controls (see "Safety notes" in the README); it does not
open network ports. Neither program needs administrator rights, and the installer only writes to your own profile
(`%LOCALAPPDATA%\TelemostTouchpad`, and `HKCU` keys).

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** (Security tab) if it is enabled for this repository; otherwise open an
issue that describes the problem without exploit details and ask for a private channel.
