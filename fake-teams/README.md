# fake-teams

A loopback-only server that imitates the Microsoft Teams "third-party device" WebSocket API for Dell Optimizer's
Collaboration Touchpad plugin (`ws://127.0.0.1:8124`). Optimizer connects as the Teams client; the meeting state it
sees comes from `telemost-bridge`, or from the keyboard when no bridge is running. It does not touch the registry.

    dotnet run -c Release                  # listens on 127.0.0.1:8124
    dotnet run -c Release -- --port 18124  # another port (the self-test uses this)
    dotnet run -c Release -- --keys keys.txt   # also read key presses appended to a file (remote control)

Keys (console): `j` join/leave meeting, `m` mute, `v` camera, `s` share, `c` incoming chat, `x` clear unread,
`r` revoke the pairing token, `h` help/status, `q` quit. Every message from Optimizer (`<-`) and every reply (`->`) is
logged with a timestamp.

## Behaviour

- A client without a valid `token` is *unpaired*: the `meetingUpdate` has **no** `meetingState` key (Optimizer treats any
  present `meetingState`, even `{}`, as paired) and `canPair` is true during a meeting. `pair` returns
  `tokenRefresh`; the token is kept in `token-<port>.txt` next to the executable.
- Supported commands: `query-state`, `pair`, `mute`, `unmute`, `toggle-mute`, `show-video`, `hide-video`,
  `toggle-video`, `toggle-ui` (`chat`, `share-tray`), `stop-sharing`.
- `POST /bridge/state` (from `telemost-bridge`): `{"inMeeting","muted","videoOn","chatOpen","sharing","unread",
  "control","force"}`. While the bridge reports in, Telemost is the source of truth and touchpad commands never change
  the state here: without `"control": true` they are acknowledged and the real state is re-sent; with it they are queued
  for the bridge.
- `GET /bridge/commands?wait=<ms>`: long-poll for queued touchpad commands (`mute`, `unmute`, `toggle-mute`,
  `show-video`, `hide-video`, `toggle-video`, `stop-sharing`, `toggle-ui chat|share-tray`).

## Tests

    dotnet build -c Release
    pwsh -File selftest.ps1          # starts the server on port 18124 and checks the replies (does not need Optimizer)
    pwsh -File send-command.ps1 -Actions unmute,mute   # send commands to the running server as a paired client
