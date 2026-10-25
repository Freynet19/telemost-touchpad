using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows.Automation;

// Bridge between Yandex Telemost and fake-teams (which Dell Optimizer talks to as if it were Teams).
//
//   Telemost windows --UI Automation--> state --POST /bridge/state--> fake-teams --> touchpad lights
//
// Read-only by default. With --control it also applies touchpad commands (fake-teams queues them, this process
// long-polls GET /bridge/commands). What it can do to Telemost, and nothing else:
//   - InvokePattern.Invoke() (a real click) on the microphone / camera / chat check boxes, only when the state differs
//   - InvokePattern.Invoke() on "Share screen" (opens Telemost's own picker dialog; it never picks a source);
//     pressing it again while the picker is open invokes the picker's "Cancel" button (never its start button)
//   - InvokePattern.Invoke() on the stop-sharing button of the mini window while sharing
//   - while sharing, for the camera and the chat: Invoke() on the mini window's "..." button, then on the menu's
//     "Video" / "Chat" item, then closing that menu window (WindowPattern.Close() if it did not close itself);
//     a second chat press closes the "Meeting chat" window (WindowPattern.Close(), checked by its class)
// It never touches participants, reactions, invite, menu or "end call".
//
// Telemost has two UIs: the normal call window, and while a screen is shared a mini window plus a
// "Screen sharing on" HUD (the call window is then hidden and not even visible to UI Automation).
//
// Usage: telemost-bridge [--endpoint http://127.0.0.1:8124/bridge/state] [--poll 500] [--control] [--once] [--dry]

string endpoint = "http://127.0.0.1:8124/bridge/state";
int pollMs = 500;
bool once = false, dry = false, control = false;
for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--endpoint" when i + 1 < args.Length: endpoint = args[++i]; break;
        case "--poll" when i + 1 < args.Length: pollMs = int.Parse(args[++i]); break;
        case "--once": once = true; break;
        case "--dry": dry = true; break;
        case "--control": control = true; break;
    }
}
string commandsUrl = endpoint.Replace("/bridge/state", "/bridge/commands");

var reader = new TelemostReader();
using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(1) };
using var stop = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Cancel(); };

void Log(string message) => Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} [telemost] {message}");

if (once)
{
    Log(reader.Read().ToString());
    return 0;
}

bool unreachable = false;
DateTime lastSent = DateTime.MinValue;

async Task<bool> PostAsync(CallState state, bool force)
{
    var body = new JsonObject
    {
        ["inMeeting"] = state.InCall,
        ["muted"] = state.Muted,
        ["videoOn"] = state.VideoOn,
        ["chatOpen"] = state.ChatOpen,
        ["sharing"] = state.Sharing,
        ["unread"] = state.Unread,
        ["control"] = control,
        ["force"] = force,
    };
    try
    {
        using var response = await http.PostAsync(endpoint, new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"), stop.Token);
        response.EnsureSuccessStatusCode();
        reader.LastSent = state;
        lastSent = DateTime.UtcNow;
        if (unreachable) { Log("fake-teams reachable again"); unreachable = false; }
        return true;
    }
    catch (OperationCanceledException) when (stop.IsCancellationRequested) { return false; }
    catch (Exception ex)
    {
        if (!unreachable) { Log($"fake-teams not reachable ({ex.GetType().Name}); will keep retrying"); unreachable = true; }
        lastSent = DateTime.UtcNow - TimeSpan.FromSeconds(3); // retry in ~1 s
        return false;
    }
}

async Task CommandLoop()
{
    using var longPoll = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
    while (!stop.IsCancellationRequested)
    {
        try
        {
            string text = await longPoll.GetStringAsync($"{commandsUrl}?wait=3000", stop.Token);
            if (JsonNode.Parse(text) is not JsonArray commands) continue;
            foreach (var item in commands)
            {
                string action = (string?)item?["action"] ?? "?";
                string? param = (string?)item?["param"];
                string label = param is null ? action : $"{action} {param}";
                long ageMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - ((long?)item?["ts"] ?? 0);
                if (ageMs > 3000) { Log($"COMMAND {label}: dropped (stale, {ageMs} ms old)"); continue; }
                // Commands are handled strictly one at a time; each ends with a fresh read, so a repeated
                // "unmute" that arrives right after the first one sees the new state and does nothing.
                string result = await reader.ExecuteAsync(action, param);
                Log($"COMMAND {label}: {result}");
                await PostAsync(reader.Read(), force: true);
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        catch (Exception)
        {
            try { await Task.Delay(1000, stop.Token); } catch (OperationCanceledException) { }
        }
    }
}

Log($"bridge started; mode={(control ? "CONTROL (touchpad commands are applied)" : "read-only")}; poll={pollMs} ms; target={(dry ? "(dry run, not posting)" : endpoint)}");
Task commandTask = control && !dry ? Task.Run(CommandLoop) : Task.CompletedTask;

CallState? last = null;
while (!stop.IsCancellationRequested)
{
    var state = reader.Read();
    if (last is null || state != last)
    {
        Log(state.ToString());
        last = state;
    }

    if (!dry && (DateTime.UtcNow - lastSent > TimeSpan.FromSeconds(4) || state != reader.LastSent))
        await PostAsync(state, force: false);

    try { await Task.Delay(pollMs, stop.Token); } catch (OperationCanceledException) { }
}

await commandTask;
Log("stopped");
return 0;

/// <summary>What the bridge reports. Mini = the call is shown in the small sharing-mode window.</summary>
sealed record CallState(bool InCall, bool Muted, bool VideoOn, bool ChatOpen, bool Sharing, int Unread, bool Mini)
{
    public override string ToString() => !InCall
        ? "no call window"
        : $"in call ({(Mini ? "mini window" : "main window")}): mic={(Muted ? "MUTED" : "live")} camera={(VideoOn ? "on" : "off")}{(Mini ? "(held)" : "")} " +
          $"chatPanel={(ChatOpen ? "open" : "closed")} unread={Unread} sharing={(Sharing ? "YES" : "no")}";
}

/// <summary>
/// A Telemost check box (microphone, camera, chat). The state is read through TogglePattern. Pressing it uses
/// InvokePattern, i.e. a real click: TogglePattern.Toggle() only flips the check box's look and Telemost ignores
/// it (verified: the camera never started), while Invoke runs the app's own handler.
/// </summary>
sealed class Switch
{
    readonly TogglePattern toggle;
    readonly InvokePattern invoke;

    Switch(TogglePattern toggle, InvokePattern invoke) { this.toggle = toggle; this.invoke = invoke; }

    public ToggleState State => toggle.Current.ToggleState;
    public void Press() => invoke.Invoke();

    public static Switch? TryCreate(AutomationElement el) =>
        el.TryGetCurrentPattern(TogglePattern.Pattern, out object? t) && el.TryGetCurrentPattern(InvokePattern.Pattern, out object? i)
            ? new Switch((TogglePattern)t, (InvokePattern)i)
            : null;
}

sealed class TelemostReader
{
    const string MainWindowClass = "Telemost::TelemostWindowTelemes";
    const string MiniWindowClass = "MiniConferenceWindow";
    const string HudClass = "ScreenHUD";
    const string DialogClass = "StartScreencastDialog";
    const string MenuClass = "MiniControlPanelMenuWidget";   // the "..." popup of the mini window
    const string ChatDialogClass = "MiniConferenceChatDialog";   // "Meeting chat": the chat opened from that menu while sharing
    const string PanelClass = "ControlPanelWidget";
    const string MiniButtonIdSuffix = ".footerWidget.SimplePanelButton";

    readonly object gate = new();

    // main call window
    AutomationElement? mainWindow, chatElement, screencastButton;
    Switch? mic, camera, chat;
    // mini window (screen sharing)
    AutomationElement? miniWindow, miniStopSharing, miniMore;
    Switch? miniMic;

    // The mini window has no camera, chat or unread counter: keep the last known values meanwhile.
    bool heldVideoOn, heldChatOpen;   // camera assumed off until the main window has been seen
    int heldUnread;

    public CallState? LastSent;

    static readonly CallState NoCall = new(false, false, true, false, false, 0, false);

    static PropertyCondition ByClass(string name) => new(AutomationElement.ClassNameProperty, name);
    static AutomationElement? TopLevel(string cls) => AutomationElement.RootElement.FindFirst(TreeScope.Children, ByClass(cls));

    public CallState Read()
    {
        lock (gate) return ReadLocked();
    }

    CallState ReadLocked()
    {
        try
        {
            bool sharing = TopLevel(HudClass) is not null;

            var main = TopLevel(MainWindowClass);
            if (main is not null && AttachMain(main))
            {
                // Check boxes: ToggleState.On means "switched off" for microphone and camera (crossed-out icon),
                // and "open" for the chat panel.
                bool muted = mic!.State == ToggleState.On;
                bool videoOn = camera!.State == ToggleState.Off;
                bool chatOpen = chat is not null && chat.State == ToggleState.On;
                int unread = TrackUnread(ReadBadge(), chatOpen);
                heldVideoOn = videoOn; heldChatOpen = chatOpen; heldUnread = unread;
                return new CallState(true, muted, videoOn, chatOpen, sharing, unread, false);
            }
            ForgetMain();

            var mini = TopLevel(MiniWindowClass);
            if (mini is not null && AttachMini(mini))
            {
                bool muted = miniMic!.State == ToggleState.On;
                // The camera has no button in the mini window; it is visible only while the "..." menu is open
                // (for example when the user opened it), so refresh the held value from there when possible.
                var openMenu = TopLevel(MenuClass);
                if (openMenu is not null && FindMenuItem(openMenu, ".cameraMenuItem") is { } cameraItem && Switch.TryCreate(cameraItem) is { } cameraSwitch)
                    heldVideoOn = cameraSwitch.State == ToggleState.Off;
                // While sharing, the chat lives in its own window; its presence is the "chat open" state.
                bool chatWindowOpen = TopLevel(ChatDialogClass) is not null;
                if (chatWindowOpen) { chatWasOpen = true; heldUnread = 0; }
                heldChatOpen = chatWindowOpen;
                return new CallState(true, muted, heldVideoOn, heldChatOpen, sharing, heldUnread, true);
            }
            ForgetMini();
            return NoCall;
        }
        catch (Exception ex) when (ex is ElementNotAvailableException or InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            ForgetMain();
            ForgetMini();
            return NoCall;
        }
    }

    // The badge on the chat button is NOT an unread counter: it shows the number of messages while the chat panel is
    // closed (it stays e.g. "2" after you read them) and disappears while the panel is open. So "new messages" are
    // the growth of that number since the last time the panel was open (or since the bridge first saw it).
    int? chatBaseline;
    bool chatWasOpen;

    int TrackUnread(int badge, bool chatOpen)
    {
        if (chatOpen)
        {
            chatWasOpen = true;   // everything that arrives meanwhile is seen by the user
            return 0;
        }
        if (chatBaseline is null || chatWasOpen || badge < chatBaseline) chatBaseline = badge;
        chatWasOpen = false;
        return Math.Max(0, badge - chatBaseline.Value);
    }

    int ReadBadge()
    {
        var badge = chatElement?.FindFirst(TreeScope.Descendants, ByClass("BadgeLabel"));
        return badge is not null && int.TryParse(badge.Current.Name, out int n) ? n : 0;
    }

    // ---- commands -------------------------------------------------------------------------------------------

    public async Task<string> ExecuteAsync(string action, string? param)
    {
        // Held under the lock only for the UI Automation calls; waiting for effects happens inside the lock too,
        // which is what we want: commands are strictly serialized.
        await Task.Yield();
        lock (gate)
        {
            var now = ReadLocked();
            if (!now.InCall) return "no call window, nothing done";

            switch (action, param)
            {
                case ("mute", _): return Mic(now, wantMuted: true);
                case ("unmute", _): return Mic(now, wantMuted: false);
                case ("toggle-mute", _): return Mic(now, wantMuted: !now.Muted);
                case ("hide-video", _): return Camera(now, wantVideoOn: false);
                case ("show-video", _): return Camera(now, wantVideoOn: true);
                case ("toggle-video", _): return Camera(now, wantVideoOn: !now.VideoOn);
                case ("toggle-ui", "chat"): return Chat(now);
                case ("toggle-ui", "share-tray"): return OpenShareDialog(now);
                case ("stop-sharing", _): return StopSharing(now);
                default: return "not a supported command, ignored";
            }
        }
    }

    string Mic(CallState now, bool wantMuted)
    {
        var button = now.Mini ? miniMic! : mic!;
        string where = now.Mini ? "mic (mini window)" : "mic";
        return SetToggle(button, where, wantOn: wantMuted, currentOn: now.Muted, offName: "MUTED", onName: "live");
    }

    static AutomationElement? FindMenuItem(AutomationElement menu, string idSuffix) =>
        menu.FindAll(TreeScope.Descendants, Condition.TrueCondition).Cast<AutomationElement>()
            .FirstOrDefault(e => e.Current.AutomationId.EndsWith(idSuffix, StringComparison.Ordinal));

    /// <summary>
    /// While sharing, the camera and the chat are reachable only through the "..." menu of the mini window: open it
    /// (Invoke on the mini window's third button), run <paramref name="action"/> on it, then close the menu. Only the
    /// "..." button, the one menu item the action uses and the menu window itself are touched.
    /// </summary>
    string WithMenu(Func<AutomationElement, string> action)
    {
        if (miniMore is null) return "\"...\" button of the mini window not found, nothing done";
        if (TopLevel(MenuClass) is not null) return "menu is already open (opened by the user?), nothing done";

        ((InvokePattern)miniMore.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        AutomationElement? menu = null;
        WaitFor(() => (menu = TopLevel(MenuClass)) is not null, 1500);
        if (menu is null) return "menu did not appear within 1.5 s, nothing done";

        string result, closeNote;
        try { result = action(menu); }
        finally { closeNote = CloseMenu(); }
        return $"{result}; menu {closeNote}";
    }

    string CameraViaMenu(bool wantVideoOn) => WithMenu(menu =>
    {
        var item = FindMenuItem(menu, ".cameraMenuItem");
        var video = item is null ? null : Switch.TryCreate(item);
        if (video is null) return "Video item not found in the menu, nothing done";

        bool videoOnNow = video.State == ToggleState.Off;   // check box On == camera off
        heldVideoOn = videoOnNow;
        if (videoOnNow == wantVideoOn) return $"camera already {(wantVideoOn ? "ON" : "OFF")}, nothing to do";

        var want = wantVideoOn ? ToggleState.Off : ToggleState.On;
        video.Press();   // <- the write: a real click on the menu's Video item
        heldVideoOn = video.State == ToggleState.Off;
        return WaitFor(() => video.State == want)
            ? $"camera (via menu) toggled -> {(wantVideoOn ? "ON" : "OFF")}"
            : "camera (via menu) clicked but state not confirmed after 2 s";
    });

    /// <summary>
    /// Chat while sharing: it is a separate "Meeting chat" window. Closed -> open it through the menu's Chat item;
    /// open -> close exactly that window (checked by its class, never the main Telemost window).
    /// </summary>
    string ChatWhileSharing()
    {
        var chatWindow = TopLevel(ChatDialogClass);
        if (chatWindow is not null)
        {
            if (!chatWindow.TryGetCurrentPattern(WindowPattern.Pattern, out object? window)) return "chat window cannot be closed (no Window pattern), nothing done";
            ((WindowPattern)window).Close();
            return WaitFor(() => TopLevel(ChatDialogClass) is null)
                ? "chat window closed"
                : "chat window still open after 2 s";
        }

        return WithMenu(menu =>
        {
            var item = FindMenuItem(menu, ".chatMenuItem");
            if (item is null || !item.TryGetCurrentPattern(InvokePattern.Pattern, out object? invoke)) return "Chat item not found in the menu, nothing done";
            ((InvokePattern)invoke).Invoke();   // <- the write: opens the chat window
            return WaitFor(() => TopLevel(ChatDialogClass) is not null, 3000)
                ? "chat window opened"
                : "Chat clicked but no chat window appeared within 3 s";
        });
    }

    /// <summary>
    /// A click on a menu item usually closes the popup by itself. If it is still there after 0.7 s, ask that one
    /// window to close (WindowPattern.Close(); no keystrokes, no mouse). If even that fails, leave it to the user.
    /// </summary>
    string CloseMenu()
    {
        if (WaitFor(() => TopLevel(MenuClass) is null, 700)) return "closed by itself";
        var menu = TopLevel(MenuClass);
        if (menu is null) return "closed by itself";
        if (menu.TryGetCurrentPattern(WindowPattern.Pattern, out object? window)) ((WindowPattern)window).Close();
        return WaitFor(() => TopLevel(MenuClass) is null, 1500) ? "closed with WindowPattern.Close()" : "STILL OPEN (click elsewhere to close it)";
    }

    string Camera(CallState now, bool wantVideoOn)
    {
        if (now.Mini) return CameraViaMenu(wantVideoOn);
        return SetToggle(camera!, "camera", wantOn: !wantVideoOn, currentOn: !now.VideoOn, offName: "OFF", onName: "ON");
    }

    string Chat(CallState now)
    {
        if (now.Mini) return ChatWhileSharing();
        if (chat is null) return "chat button not found, nothing done";
        var button = chat;
        bool wasOpen = now.ChatOpen;
        button.Press();
        return WaitFor(() => (button.State == ToggleState.On) != wasOpen)
            ? $"chat panel toggled -> {(wasOpen ? "closed" : "open")}"
            : "chat toggled but state not confirmed after 2 s";
    }

    string OpenShareDialog(CallState now)
    {
        if (now.Sharing) return "already sharing, nothing done";
        if (now.Mini || screencastButton is null) return "share button not available, nothing done";
        if (!screencastButton.Current.IsEnabled) return "Share screen button is disabled in Telemost, nothing done";
        var openDialog = mainWindow!.FindFirst(TreeScope.Descendants, ByClass(DialogClass));
        if (openDialog is not null)
        {
            // Second press while the picker is open: close it with its own Cancel button.
            // The "Share screen" (start) button of the dialog is never touched.
            var cancel = FindMenuItem(openDialog, ".cancelButton");
            if (cancel is null) return "share dialog is open but its Cancel button was not found, nothing done";
            ((InvokePattern)cancel.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
            return WaitFor(() => mainWindow!.FindFirst(TreeScope.Descendants, ByClass(DialogClass)) is null)
                ? "share dialog cancelled (nothing is shared)"
                : "Cancel invoked but the share dialog is still open after 2 s";
        }

        // Opens Telemost's own picker; choosing what to share is left to the user.
        ((InvokePattern)screencastButton.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        return WaitFor(() => mainWindow!.FindFirst(TreeScope.Descendants, ByClass(DialogClass)) is not null)
            ? "share dialog opened (waiting for you to pick a screen/window)"
            : "Share screen invoked but the dialog did not appear within 2 s";
    }

    string StopSharing(CallState now)
    {
        if (!now.Sharing) return "not sharing, nothing done";
        if (miniStopSharing is null) return "stop-sharing button of the mini window not found, nothing done";
        ((InvokePattern)miniStopSharing.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        return WaitFor(() => TopLevel(HudClass) is null, 3000)
            ? "sharing stopped"
            : "stop invoked but sharing indicator still present after 3 s";
    }

    // "On" == switched off (muted / camera off) for the microphone and camera buttons.
    string SetToggle(Switch button, string name, bool wantOn, bool currentOn, string offName, string onName)
    {
        // wantOn/currentOn describe the check box ("On" = muted / camera off); offName/onName describe the result.
        if (wantOn == currentOn) return $"{name} already {(wantOn ? offName : onName)}, nothing to do";
        var want = wantOn ? ToggleState.On : ToggleState.Off;
        var started = DateTime.UtcNow;
        button.Press();   // <- the write (microphone/camera): a real click via InvokePattern
        return WaitFor(() => button.State == want)
            ? $"{name} toggled -> {(wantOn ? offName : onName)} (confirmed in {(int)(DateTime.UtcNow - started).TotalMilliseconds} ms)"
            : $"{name} toggled but state not confirmed after 2 s";
    }

    static bool WaitFor(Func<bool> condition, int timeoutMs = 2000)
    {
        var started = DateTime.UtcNow;
        while ((DateTime.UtcNow - started).TotalMilliseconds < timeoutMs)
        {
            if (condition()) return true;
            Thread.Sleep(50);
        }
        return false;
    }

    // ---- attaching ------------------------------------------------------------------------------------------

    void ForgetMain() { mainWindow = chatElement = screencastButton = null; mic = camera = chat = null; }
    void ForgetMini() { miniWindow = miniStopSharing = miniMore = null; miniMic = null; }

    bool AttachMain(AutomationElement window)
    {
        if (mainWindow is not null && mainWindow.Equals(window) && mic is not null && camera is not null) return true;
        ForgetMain();

        var panel = window.FindFirst(TreeScope.Descendants, ByClass(PanelClass));
        if (panel is null) return false;

        foreach (AutomationElement el in panel.FindAll(TreeScope.Descendants, Condition.TrueCondition))
        {
            string id = el.Current.AutomationId;
            if (id.EndsWith(".screencastButton", StringComparison.Ordinal)) { screencastButton = el; continue; }
            if (el.Current.ControlType != ControlType.CheckBox) continue;
            var sw = Switch.TryCreate(el);
            if (sw is null) continue;
            if (id.EndsWith(".microphoneButton", StringComparison.Ordinal)) mic = sw;
            else if (id.EndsWith(".cameraButton", StringComparison.Ordinal)) camera = sw;
            else if (id.EndsWith(".chatButton", StringComparison.Ordinal)) { chat = sw; chatElement = el; }
        }
        if (mic is null || camera is null) { ForgetMain(); return false; }
        mainWindow = window;
        return true;
    }

    bool AttachMini(AutomationElement window)
    {
        if (miniWindow is not null && miniWindow.Equals(window) && miniMic is not null) return true;
        ForgetMini();

        // The three footer buttons share one AutomationId; their left-to-right order is: microphone (check box),
        // stop sharing (green laptop), "more".
        var buttons = window.FindAll(TreeScope.Descendants, Condition.TrueCondition)
            .Cast<AutomationElement>()
            .Where(e => e.Current.AutomationId.EndsWith(MiniButtonIdSuffix, StringComparison.Ordinal))
            .OrderBy(e => e.Current.BoundingRectangle.X)
            .ToList();
        if (buttons.Count != 3) return false;
        miniMic = Switch.TryCreate(buttons[0]);
        if (miniMic is null) return false;

        miniStopSharing = buttons[1];
        miniMore = buttons[2];
        miniWindow = window;
        return true;
    }
}
