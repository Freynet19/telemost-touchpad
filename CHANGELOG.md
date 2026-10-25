# Changelog

## 0.2.0 - 2026-10-25

- Chat from the touchpad while sharing: opens the "Meeting chat" window through the mini window's "..." menu, and a
  second press closes that window.

## 0.1.0 - 2026-10-25

First version.

- `fake-teams`: imitates the Microsoft Teams third-party device API for Dell Optimizer (pairing, meeting state,
  commands) and relays touchpad commands to the bridge.
- `telemost-bridge`: reads the Yandex Telemost call window through UI Automation and applies microphone, camera,
  screen-share and chat commands with real clicks; also works while sharing (mini window, "..." menu for the camera).
- Per-user install / uninstall / autostart scripts (`-WhatIf` supported), `build.ps1`, read-only probe scripts,
  a self-test for the server, research notes.
- Tested with Dell Optimizer 4.2.4.0, Yandex Telemost 3.2.2.10363, Windows 11 (10.0.26300), Dell Latitude 9440.
