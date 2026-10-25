# Research notes

How Dell Optimizer's Collaboration Touchpad support and Yandex Telemost behave, as found while building this project
(Dell Optimizer 4.2.4.0, Telemost 3.2.2.10363, Dell Latitude 9440, Windows 11). Items are marked **[verified]**
(observed in logs or behaviour on the real machine) or **[inferred]** (from reading code/static analysis only).
Versions will drift; use this as a map when something stops working.

## Dell Optimizer side

Files (`C:\Program Files\Dell\DellOptimizer\Plugins\Bootstrap\`):

| File | Role |
|---|---|
| `Dell.Optimizer.Plugin.CollaborationTouchpad.dll` | managed plugin; wraps the native agent; BIOS attribute `COLLABORATION_TOUCHPAD`, brightness, click mode |
| `CollaborationTouchpadPlugin.CTPAgent.dll` | native; talks to the touchpad over HID |
| `Dell.Optimizer.Plugin.VoipApps.dll` | managed; Teams, Zoom (SDK) and Webex "agents" that report the meeting state and execute button presses |

The managed DLLs can be decompiled with ILSpy. Nothing in this project modifies them.

### Touchpad HID **[inferred, partly verified]**

- HID-over-I2C device, VID `0x0488` PID `0x104C`; the collaboration buttons are the collection with top-level usage
  page `0xFF80`, usage `0x80` (Windows shows it as `HID\VID_0488&UP:FF80_U:0080`; it was `COL08` here).
- The native agent opens it with `CreateFileW(... GENERIC_READ|WRITE, shareMode = 0, FILE_FLAG_OVERLAPPED)`, i.e.
  **exclusively**. A second program cannot open it while Optimizer holds it (error 32 even for a zero-access open).
  This is why the project goes through Optimizer instead of talking to the touchpad.
- It uses the HID parser (`HidP_*`) by usage: input usages `0x40` sync, `0x41` camera, `0x42` share, `0x43` chat,
  `0x44` microphone, `0x45` gesture, `0x46` enabled, `0x47` disabled, value `0x48`; output `0x30` request and
  LED usages per button (camera `0x20/0x21`, microphone `0x26/0x27`, chat `0x24`, share `0x22`); feature `0x61/0x62`
  click mode; haptics `0x0E:0x23`. Report IDs are not in the code (they come from the device descriptor).
- Other collections of the same device are the mouse, the Precision Touchpad and vendor pages `0xFF00`/`0xFF01`
  (not used by the agent).

### Teams API client **[verified]**

Optimizer connects to `ws://127.0.0.1:8124?protocol-version=2.0.0&app=Dell Optimizer&manufacturer=Dell Inc.&device=Dell Collaboration Touchpad&app-version=<v>[&token=<t>]`.

- Client -> server: `{"action": "...", "requestId": n, "parameters": {"type": "..."}}` with actions `query-state`,
  `pair`, `mute`, `unmute`, `show-video`, `hide-video`, `toggle-mute`, `toggle-video`, `toggle-ui`
  (`chat` | `share-tray`), `stop-sharing`.
- Server -> client: `{"meetingUpdate": {"meetingState": {...}, "meetingPermissions": {...}}}`. `meetingState` has
  `isMuted`, `isVideoOn`, `isInMeeting`, `isSharing`, `numUnreadMessages`/`hasUnreadMessages`; `meetingPermissions` has
  `canToggleMute`, `canToggleVideo`, `canToggleChat`, `canToggleShareTray`, `canPair`, `canLeave`, ...
- **Paired vs unpaired is decided only by whether the `meetingState` object is present** (even `{}` counts as paired).
  An unpaired client must get a `meetingUpdate` without that key and `canPair: true`; Optimizer then sends `pair`
  about 250 ms later and expects `{"tokenRefresh": "<token>"}`, which it stores under
  `HKLM\SOFTWARE\Dell\DellOptimizer\PData\<user SID>` and sends back as `&token=` on later connections.
- Button semantics: microphone/camera send explicit `mute`/`unmute`/`hide-video`/`show-video` based on Optimizer's own
  idea of the button state, chat sends `toggle-ui chat`, share sends `toggle-ui share-tray` when not sharing and
  `stop-sharing` when sharing. Optimizer repeats commands while the reported state does not change.
- The chat button breathes when `numUnreadMessages` increases.

### When Optimizer connects at all **[verified]**

It decides "Teams is installed" from `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams` (any content), or
the `MSTeams_8wekyb3d8bbwe` package, or a running `Teams`/`ms-teams` process. After a failed attempt it retries every
30 s (10 s after socket errors) only while that holds; it also retries after logon events and whenever something asks
for the Teams state.

## Yandex Telemost side

Qt 6 + QtWebEngine application. Its widgets expose a native UI Automation tree.

- Call window: class `Telemost::TelemostWindowTelemes`, panel `ControlPanelWidget` with `microphoneButton`,
  `cameraButton`, `chatButton` (check boxes), `screencastButton` (button), `participantsButton`, `reactionsButton`,
  `inviteButton`, `menuButton`, `endCallButton`. Window titles/names of the icon buttons are empty: identify by
  AutomationId suffix. **[verified]**
- Check box state: `ToggleState.On` means *switched off* for microphone and camera (crossed-out icon) and *open* for
  chat. **[verified]**
- **`TogglePattern.Toggle()` only flips the check box's look; Telemost ignores it** (the camera never started).
  **`InvokePattern.Invoke()` behaves like a real click** and runs the application's handler (the Windows webcam usage
  record showed start/stop). **[verified]**
- The chat badge is the number of messages while the panel is closed (it comes back after closing); it is not an
  unread counter. New messages = growth of that number. **[verified]**
- Screen share: `Invoke` on `screencastButton` opens `StartScreencastDialog` (list of screens/windows, `Share computer
  sound`, `startButton`, `cancelButton`). While sharing, the call window is hidden and disappears from UI Automation
  entirely; instead there is `MiniConferenceWindow` (footer: microphone check box, stop-sharing button, "..." button,
  all with the same AutomationId, in that left-to-right order) and a `ScreenHUD` window ("Screen sharing on", its
  presence means sharing). **[verified]**
- The "..." button opens `MiniControlPanelMenuWidget` (separate popup window): `microphoneMenuItem`, `cameraMenuItem`
  ("Video", check box), `videoMenuItem` ("Stop"), `reactionMenuItem`, `participantsMenuItem`, `chatMenuItem`,
  `localRecordMenuItem`, `permissionsMenuItem`, `settingsMenuItem`, `endCallMenuItem`. It closes by itself after a click on
  an item. This is the only place the camera is reachable while sharing. **[verified]**
- Clicking the menu's Chat item opens the chat as its own window, `MiniConferenceChatDialog` titled "Meeting chat"
  (a Qt dialog hosting a QtWebEngine page; no minimise/maximise, supports the Window pattern, so
  `WindowPattern.Close()` closes just that dialog). It is not the main application window (`Messenger::MessengerWindow`,
  title "Yandex Telemost"), which must never be closed this way. The window's presence is the "chat open" state while
  sharing. **[verified]**
- Windows' privacy record
  `HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged\C:#Program Files#Yandex#YandexTelemost#YandexTelemost.exe`
  (`LastUsedTimeStart/Stop`) is a handy objective check that the camera really started. It keeps only the last session.

## Exploring it yourself

The scripts in `telemost-probe/` are read-only unless named `*-test.ps1` (those change the camera and restore it):
`probe-windows.ps1` (windows + webcam record), `probe-uia.ps1 -Hwnd 0x...` (UI Automation tree),
`probe-uia-props.ps1`, `probe-modes.ps1` (which Telemost windows exist), `probe-audio.ps1` (WASAPI sessions),
`diff-snapshot.ps1` (compare against a baseline: first save `windows-before.txt` and `uia-before.txt` next to it from
`probe-windows.ps1` / `probe-uia.ps1` output).
