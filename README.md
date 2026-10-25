# Telemost Touchpad

Makes the **Dell Collaboration Touchpad** buttons (microphone, camera, screen share, chat) work with the
**Yandex Telemost** desktop app, which Dell Optimizer does not support. Tested on a Dell Latitude 9440.

[Русская версия](README.ru.md)

> **Status:** works for the author on one machine (see [Requirements](#requirements)). It is unofficial and relies on
> undocumented behaviour of Dell Optimizer and Yandex Telemost; either may break it with an update.
> Not affiliated with Dell, Yandex or Microsoft. See [Legal](#legal).

## What it does

Dell Optimizer lights and reads the touchpad buttons when a Zoom/Teams/Webex meeting is running. For Teams it talks to
a local WebSocket API. This project plays Teams for Optimizer and connects that to Telemost:

```
touchpad button --> Dell Optimizer --(Teams API, ws://127.0.0.1:8124)--> fake-teams --> telemost-bridge --UI Automation--> Telemost
touchpad lights <-- Dell Optimizer <------------ meeting state ---------- fake-teams <-- telemost-bridge <-- Telemost
```

- `fake-teams` — a loopback-only server that speaks Teams' "third-party device" API to Optimizer.
- `telemost-bridge` — reads the Telemost call window through UI Automation and applies touchpad commands to it.

| Touchpad button | Normal call window | While sharing the screen (mini window) |
|---|---|---|
| Microphone | mutes / unmutes for real | works (mini window's mic button) |
| Camera | starts / stops the camera for real | works (through the "…" menu, which flashes briefly) |
| Share | opens Telemost's own picker; pressing again cancels it | stops sharing |
| Chat | opens / closes the chat panel | not available |

The lights follow the real Telemost state, also when you change it with the mouse. The chat button breathes when new
messages arrive while the chat is closed. Buttons are lit only while a call window exists; with just the main Telemost
window open they stay dark. (The pre-join screen has not been tested.)

## Requirements

- A Dell laptop with the Collaboration Touchpad and **Dell Optimizer** (tested: Latitude 9440, Optimizer 4.2.4.0).
- **Yandex Telemost** desktop app (tested: 3.2.2.10363), Windows 11 (tested: 10.0.26300).
- .NET 10 runtimes, x64: *.NET Desktop Runtime* and *ASP.NET Core Runtime*. The .NET 10 SDK to build.
- No administrator rights needed.

Real Microsoft Teams must not run at the same time (it would use port 8124).

## Install

```powershell
git clone <this repository>
cd telemost-touchpad
.\build.ps1                                                        # publishes both programs into .\dist
powershell -ExecutionPolicy Bypass -File .\dist\install.ps1 -WhatIf   # preview, changes nothing
powershell -ExecutionPolicy Bypass -File .\dist\install.ps1
```

`install.ps1` (per user):

- copies the programs to `%LOCALAPPDATA%\TelemostTouchpad` (logs go to `logs\`);
- creates `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams` with `DisplayName=Teams` if it does not
  exist. Optimizer only keeps trying to reach the Teams API while it believes Teams is installed; this key is how it
  checks. Its content does not matter;
- registers `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\TelemostTouchpad` so everything starts hidden at logon;
- starts everything. Optimizer connects within about 30 seconds.

The first time, Optimizer pairs by itself during the first meeting (it stores its token under
`HKLM\SOFTWARE\Dell\DellOptimizer\PData`).

No Dell or Telemost file is modified.

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\dist\uninstall.ps1 -WhatIf
powershell -ExecutionPolicy Bypass -File .\dist\uninstall.ps1
```

It removes the autostart entry, stops the programs and deletes the install folder. The `Uninstall\Teams` key is
removed only if it looks like the one `install.ps1` created. Optimizer's own `HKLM\...\PData` record needs an
administrator and is optional to delete.

## Resource use

Measured during a call: `fake-teams` about 0.4 % of one core and 50 MB; `telemost-bridge` about 2 % of one core and
60 MB (it polls UI Automation every 0.5 s). Loopback traffic only. UI Automation queries make Telemost (Qt) switch on
its accessibility mode, which may cost it a little.

## Safety notes

- The bridge touches Telemost only with real clicks (`InvokePattern`) on the microphone, camera, chat and screen-share
  controls, the "Cancel" button of the share picker, the stop-sharing button of the mini window and, for the camera
  while sharing, the "…" menu and its "Video" item. It never touches "end call", settings, participants, recording, or
  the picker's start button; it never chooses what to share.
- Everything listens on `127.0.0.1` only, but **without authentication**: any local process could pretend to be
  Optimizer or the bridge (the pairing token is not a secret). This is acceptable on a single-user machine, not on a
  shared one.

## If it stops working

1. Running? `Get-Process fake-teams, telemost-bridge`. If not, run `%LOCALAPPDATA%\TelemostTouchpad\start.ps1` and read
   `logs\*.err.log` (port 8124 busy = real Teams or another copy is running).
2. Does Optimizer connect? `logs\fake-teams.log` must show `[++] ... app='Dell Optimizer'` within ~30 s of the start.
   If not after a Dell update: check that the `Uninstall\Teams` key exists, and compare Optimizer's
   `Plugins\Bootstrap\Dell.Optimizer.Plugin.VoipApps.dll` version with `VERSION.txt` of your build
   (see [docs/research-notes.md](docs/research-notes.md)).
3. Connected, but the buttons do nothing? Look for `touchpad '...' -> forwarded` in `fake-teams.log` (presses arrive)
   and for `COMMAND ...` in `telemost-bridge.log`.
4. `no call window` during a call? Telemost changed its UI. Run `telemost-probe\probe-uia.ps1` (read-only) against the
   call window and compare class names / AutomationIds with the constants at the top of
   `telemost-bridge\Program.cs`.

## Repository layout

| Path | Contents |
|---|---|
| `fake-teams/` | the fake Teams API server (ASP.NET Core) and its self-test (`selftest.ps1`) |
| `telemost-bridge/` | the Telemost reader / controller (UI Automation) |
| `telemost-probe/` | read-only diagnostic scripts used to explore Telemost (window tree, audio sessions, ...) and two small experiments |
| `scripts/` | `install.ps1`, `uninstall.ps1`, `start.ps1`, `stop.ps1` (copied into `dist\` by the build) |
| `docs/research-notes.md` | how Dell Optimizer's touchpad plugin and Telemost behave, as found while building this |
| `build.ps1` | builds both programs and assembles `dist\` |

Run the server's self-test (needs `dotnet build -c Release fake-teams` first): `pwsh fake-teams\selftest.ps1`.

## Known limitations

- Chat cannot be driven while sharing (the mini window has no chat toggle).
- The share picker still has to be used by hand to choose a screen or window.
- Camera control while sharing opens the "…" menu for a moment.
- Commands pressed while the bridge is not running are lost (older than 3 s are dropped).
- Depends on Telemost's internal control names and on Optimizer treating this server as Teams.

## Legal

Unofficial interoperability project for the author's own hardware. Not affiliated with, endorsed by or supported by
Dell, Yandex or Microsoft; all product names and trademarks belong to their owners. This repository contains no Dell,
Yandex or Microsoft code or binaries; it only imitates, on the loopback interface, the behaviour of a local API that
Dell Optimizer expects from Microsoft Teams. Use at your own risk.

## License

[MIT](LICENSE) © 2026 Gordey Smirnov.
