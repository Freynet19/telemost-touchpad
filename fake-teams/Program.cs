using System.Collections.Concurrent;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;

// Fake "Microsoft Teams third-party device API" server for Dell Optimizer's Collaboration Touchpad.
// Optimizer connects to ws://127.0.0.1:8124 as a Teams client; this server plays Teams and lets the
// keyboard drive the simulated meeting state. Loopback only. Does not touch the registry.

const string ApiVersion = "2.0.0";
var BridgeTimeout = TimeSpan.FromSeconds(10);

int port = 8124;
string? keysPath = null;
for (int i = 0; i < args.Length - 1; i++)
{
    if (args[i] == "--port") port = int.Parse(args[i + 1]);
    if (args[i] == "--keys") keysPath = Path.GetFullPath(args[i + 1]);
}

var tokenPath = Path.Combine(AppContext.BaseDirectory, $"token-{port}.txt");
var meeting = new Meeting { Token = File.Exists(tokenPath) ? File.ReadAllText(tokenPath).Trim() : null };
var clients = new ConcurrentDictionary<int, Client>();
var commandQueue = Channel.CreateUnbounded<JsonObject>();   // touchpad commands waiting for telemost-bridge
var consoleLock = new object();
var quit = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; quit.Cancel(); };

void Log(string tag, string message)
{
    lock (consoleLock) Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} [{tag}] {message}");
}

JsonObject BuildUpdate(bool paired, int? requestId = null)
{
    bool inMeeting, muted, videoOn, sharing;
    int unread;
    lock (meeting)
    {
        inMeeting = meeting.InMeeting;
        muted = meeting.Muted;
        videoOn = meeting.VideoOn;
        sharing = meeting.Sharing;
        unread = meeting.Unread;
    }

    // Optimizer decides "paired" purely by whether the meetingState object is present (even an empty
    // one counts), so unpaired clients must get a meetingUpdate without that key at all.
    JsonObject? state = paired
        ? new JsonObject
        {
            ["isMuted"] = muted,
            ["isVideoOn"] = videoOn,
            ["isHandRaised"] = false,
            ["isInMeeting"] = inMeeting,
            ["isRecordingOn"] = false,
            ["isBackgroundBlurred"] = false,
            ["isSharing"] = sharing,
            ["hasUnreadMessages"] = unread > 0,
            ["numUnreadMessages"] = unread,
        }
        : null;

    var permissions = new JsonObject
    {
        ["canToggleMute"] = inMeeting,
        ["canToggleVideo"] = inMeeting,
        ["canToggleHand"] = inMeeting,
        ["canToggleBlur"] = inMeeting,
        ["canToggleRecord"] = false,
        ["canLeave"] = inMeeting,
        ["canReact"] = inMeeting,
        ["canToggleShareTray"] = inMeeting,
        ["canToggleChat"] = inMeeting,
        ["canStopSharing"] = inMeeting && sharing,
        ["canPair"] = inMeeting && !paired,
    };

    var update = new JsonObject();
    if (state != null) update["meetingState"] = state;
    update["meetingPermissions"] = permissions;
    var root = new JsonObject { ["apiVersion"] = ApiVersion, ["meetingUpdate"] = update };
    if (requestId is int id) root["requestId"] = id;
    return root;
}

async Task SendAsync(Client client, JsonObject message)
{
    var json = message.ToJsonString();
    var bytes = Encoding.UTF8.GetBytes(json);
    await client.Gate.WaitAsync();
    try
    {
        if (client.Socket.State != WebSocketState.Open) return;
        await client.Socket.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
        Log("->", $"#{client.Id} {json}");
    }
    catch (Exception ex)
    {
        Log("!!", $"#{client.Id} send failed: {ex.Message}");
    }
    finally
    {
        client.Gate.Release();
    }
}

async Task BroadcastAsync()
{
    foreach (var client in clients.Values)
        await SendAsync(client, BuildUpdate(client.Paired));
}

static bool Set(ref bool field, bool? value)
{
    if (value is not bool v || v == field) return false;
    field = v;
    return true;
}

JsonObject Ack(int? requestId) => With(new JsonObject { ["apiVersion"] = ApiVersion, ["response"] = "Success" }, requestId);

JsonObject Error(int? requestId, string? action, string text) =>
    With(new JsonObject { ["apiVersion"] = ApiVersion, ["action"] = action, ["errorMsg"] = text }, requestId);

static JsonObject With(JsonObject o, int? requestId)
{
    if (requestId is int id) o["requestId"] = id;
    return o;
}

string Status()
{
    lock (meeting)
    {
        return $"meeting={(meeting.InMeeting ? "ON" : "off")} mic={(meeting.Muted ? "MUTED" : "live")} " +
               $"camera={(meeting.VideoOn ? "on" : "off")} share={(meeting.Sharing ? "ON" : "off")} " +
               $"unread={meeting.Unread} chatPanel={(meeting.ChatOpen ? "open" : "closed")} " +
               $"token={(meeting.Token == null ? "none" : "issued")} clients={clients.Count}";
    }
}

async Task HandleCommandAsync(Client client, JsonObject message)
{
    int? requestId = null;
    try { requestId = (int?)message["requestId"]; } catch { }
    var action = (string?)message["action"];
    var param = (string?)message["parameters"]?["type"];

    if (action == "query-state")
    {
        await SendAsync(client, BuildUpdate(client.Paired, requestId));
        return;
    }

    if (action == "pair")
    {
        string token;
        lock (meeting)
        {
            meeting.Token ??= Guid.NewGuid().ToString("N");
            token = meeting.Token;
        }
        File.WriteAllText(tokenPath, token);
        client.Paired = true;
        Log("**", $"#{client.Id} paired (token issued)");
        await SendAsync(client, With(new JsonObject { ["apiVersion"] = ApiVersion, ["response"] = "Success", ["tokenRefresh"] = token }, requestId));
        await SendAsync(client, BuildUpdate(true));
        return;
    }

    if (!client.Paired)
    {
        await SendAsync(client, Error(requestId, action, "Pairing required"));
        return;
    }
    bool inMeeting;
    lock (meeting) inMeeting = meeting.InMeeting;
    if (!inMeeting)
    {
        await SendAsync(client, Error(requestId, action, "Not in a meeting"));
        return;
    }

    // While the Telemost bridge is feeding real state, touchpad presses must not change anything here:
    // acknowledge and re-send the real state so the button lights snap back to what Telemost shows.
    bool bridgeActive, bridgeControl;
    lock (meeting)
    {
        bridgeActive = DateTime.UtcNow - meeting.LastBridgeUtc < BridgeTimeout;
        bridgeControl = meeting.BridgeControl;
    }

    // Control mode: the bridge applies these commands to Telemost itself and pushes the resulting real state.
    bool forwardable = action is "toggle-mute" or "mute" or "unmute" or "toggle-video" or "show-video" or "hide-video" or "stop-sharing"
                       || (action == "toggle-ui" && param is "chat" or "share-tray");
    if (bridgeActive && bridgeControl && forwardable)
    {
        Log("BR", $"#{client.Id} touchpad '{action}{(param != null ? " " + param : "")}' -> forwarded to telemost-bridge");
        commandQueue.Writer.TryWrite(new JsonObject { ["action"] = action, ["param"] = param, ["ts"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
        await SendAsync(client, Ack(requestId));
        return;
    }

    if (bridgeActive && action is "toggle-mute" or "mute" or "unmute" or "toggle-video" or "show-video" or "hide-video" or "stop-sharing" or "toggle-ui")
    {
        Log("BR", $"#{client.Id} touchpad '{action}{(param != null ? " " + param : "")}' ignored (read-only stage); resending real state");
        await SendAsync(client, Ack(requestId));
        await BroadcastAsync();
        return;
    }

    string effect;
    lock (meeting)
    {
        switch (action)
        {
            case "toggle-mute": meeting.Muted = !meeting.Muted; effect = $"mic {(meeting.Muted ? "muted" : "live")}"; break;
            case "mute": meeting.Muted = true; effect = "mic muted"; break;
            case "unmute": meeting.Muted = false; effect = "mic live"; break;
            case "toggle-video": meeting.VideoOn = !meeting.VideoOn; effect = $"camera {(meeting.VideoOn ? "on" : "off")}"; break;
            case "show-video": meeting.VideoOn = true; effect = "camera on"; break;
            case "hide-video": meeting.VideoOn = false; effect = "camera off"; break;
            case "stop-sharing": meeting.Sharing = false; effect = "sharing stopped"; break;
            case "toggle-ui" when param == "chat":
                meeting.ChatOpen = !meeting.ChatOpen;
                if (meeting.ChatOpen) meeting.Unread = 0;
                effect = $"chat panel {(meeting.ChatOpen ? "opened" : "closed")}";
                break;
            case "toggle-ui" when param == "share-tray":
                meeting.Sharing = true; // simulation: pretend the user picked something to share
                effect = "share tray opened (simulated: sharing started)";
                break;
            default: effect = ""; break;
        }
    }

    if (effect.Length == 0)
    {
        Log("??", $"#{client.Id} unknown action '{action}' param '{param}'");
        await SendAsync(client, Error(requestId, action, "Unknown action"));
        return;
    }

    Log("**", $"#{client.Id} {action}{(param != null ? " " + param : "")}: {effect}");
    await SendAsync(client, Ack(requestId));
    await BroadcastAsync();
    Log("ST", Status());
}

void ShowHelp()
{
    lock (consoleLock)
    {
        Console.WriteLine("""
            keys:  j join/leave meeting   m mute   v camera   s share   c incoming chat   x clear unread
                   r revoke token (client becomes unpaired)   h help/status   q quit
            """);
    }
}

async Task HandleKeyAsync(char key)
{
    switch (char.ToLowerInvariant(key))
    {
        case 'j':
            lock (meeting)
            {
                meeting.InMeeting = !meeting.InMeeting;
                meeting.Muted = false;
                meeting.VideoOn = true;
                meeting.Sharing = false;
                meeting.ChatOpen = false;
                meeting.Unread = 0;
            }
            break;
        case 'm': lock (meeting) meeting.Muted = !meeting.Muted; break;
        case 'v': lock (meeting) meeting.VideoOn = !meeting.VideoOn; break;
        case 's': lock (meeting) meeting.Sharing = !meeting.Sharing; break;
        case 'c': lock (meeting) if (meeting.InMeeting) meeting.Unread++; break;
        case 'x': lock (meeting) meeting.Unread = 0; break;
        case 'r':
            lock (meeting) meeting.Token = null;
            if (File.Exists(tokenPath)) File.Delete(tokenPath);
            foreach (var client in clients.Values) client.Paired = false;
            Log("**", "token revoked; connected clients are now unpaired");
            break;
        case 'h': ShowHelp(); Log("ST", Status()); return;
        case 'q': quit.Cancel(); return;
        default: return;
    }
    await BroadcastAsync();
    Log("ST", Status());
}

var builder = WebApplication.CreateSlimBuilder();
builder.Logging.ClearProviders();
builder.WebHost.ConfigureKestrel(o => o.Listen(IPAddress.Loopback, port));
var app = builder.Build();
app.UseWebSockets();

app.Run(async context =>
{
    // Long-poll for telemost-bridge: GET /bridge/commands?wait=3000 -> JSON array of queued touchpad commands.
    if (context.Request.Path == "/bridge/commands")
    {
        if (!HttpMethods.IsGet(context.Request.Method)) { context.Response.StatusCode = 405; return; }
        int waitMs = int.TryParse(context.Request.Query["wait"], out var w) ? Math.Clamp(w, 0, 10000) : 3000;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
        timeout.CancelAfter(waitMs);
        var pending = new JsonArray();
        try
        {
            if (await commandQueue.Reader.WaitToReadAsync(timeout.Token))
                while (commandQueue.Reader.TryRead(out var command)) pending.Add(command);
        }
        catch (OperationCanceledException) { }
        context.Response.ContentType = "application/json";
        await context.Response.WriteAsync(pending.ToJsonString());
        return;
    }

    // Local feed from telemost-bridge: POST /bridge/state {"inMeeting":..,"muted":..,"videoOn":..,"chatOpen":..}
    if (context.Request.Path == "/bridge/state")
    {
        if (!HttpMethods.IsPost(context.Request.Method)) { context.Response.StatusCode = 405; return; }
        if (await JsonNode.ParseAsync(context.Request.Body) is not JsonObject body) { context.Response.StatusCode = 400; return; }

        bool changed = false, firstContact;
        bool force = (bool?)body["force"] ?? false;   // broadcast even if nothing changed (after a command)
        lock (meeting)
        {
            firstContact = DateTime.UtcNow - meeting.LastBridgeUtc >= BridgeTimeout;
            meeting.LastBridgeUtc = DateTime.UtcNow;
            meeting.BridgeControl = (bool?)body["control"] ?? false;
            changed |= Set(ref meeting.InMeeting, (bool?)body["inMeeting"]);
            changed |= Set(ref meeting.Muted, (bool?)body["muted"]);
            changed |= Set(ref meeting.VideoOn, (bool?)body["videoOn"]);
            changed |= Set(ref meeting.ChatOpen, (bool?)body["chatOpen"]);
            changed |= Set(ref meeting.Sharing, (bool?)body["sharing"]);
            if ((int?)body["unread"] is int unread && unread != meeting.Unread)
            {
                meeting.Unread = unread;
                changed = true;
            }
            if (!meeting.InMeeting && (meeting.Sharing || meeting.Unread != 0))
            {
                meeting.Sharing = false;
                meeting.Unread = 0;
                changed = true;
            }
        }
        if (firstContact) Log("BR", "telemost-bridge connected: Telemost state is now authoritative");
        if (firstContact) Log("BR", $"bridge control mode: {(meeting.BridgeControl ? "ON (touchpad mic/camera commands are applied to Telemost)" : "off (read-only)")}");
        if (changed || firstContact || force)
        {
            Log("BR", "state from bridge");
            await BroadcastAsync();
            Log("ST", Status());
        }
        context.Response.StatusCode = 204;
        return;
    }

    if (!context.WebSockets.IsWebSocketRequest)
    {
        context.Response.StatusCode = 426;
        return;
    }

    var query = context.Request.Query;
    var token = query["token"].ToString();
    using var socket = await context.WebSockets.AcceptWebSocketAsync();
    var client = new Client(socket);
    bool tokenMatches;
    lock (meeting) tokenMatches = token.Length > 0 && token == meeting.Token;
    client.Paired = tokenMatches;
    clients[client.Id] = client;
    Log("++", $"#{client.Id} connected: device='{query["device"]}' app='{query["app"]}' maker='{query["manufacturer"]}' " +
              $"proto={query["protocol-version"]} appver={query["app-version"]} " +
              $"token={(token.Length == 0 ? "none" : tokenMatches ? "valid" : "INVALID")}");

    try
    {
        await SendAsync(client, BuildUpdate(client.Paired));

        var buffer = new byte[8192];
        using var assembled = new MemoryStream();
        while (socket.State == WebSocketState.Open)
        {
            var result = await socket.ReceiveAsync(buffer, context.RequestAborted);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                Log("--", $"#{client.Id} closed by client ({result.CloseStatusDescription})");
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, string.Empty, CancellationToken.None);
                break;
            }
            assembled.Write(buffer, 0, result.Count);
            if (!result.EndOfMessage) continue;

            var text = Encoding.UTF8.GetString(assembled.ToArray());
            assembled.SetLength(0);
            Log("<-", $"#{client.Id} {text}");
            try
            {
                if (JsonNode.Parse(text) is JsonObject message)
                    await HandleCommandAsync(client, message);
            }
            catch (Exception ex)
            {
                Log("!!", $"#{client.Id} bad message: {ex.Message}");
            }
        }
    }
    catch (Exception ex) when (ex is WebSocketException or OperationCanceledException)
    {
        Log("--", $"#{client.Id} dropped ({ex.GetType().Name})");
    }
    finally
    {
        clients.TryRemove(client.Id, out _);
        Log("--", $"#{client.Id} disconnected");
    }
});

try
{
    await app.StartAsync();
}
catch (Exception ex)
{
    Console.Error.WriteLine($"Cannot listen on 127.0.0.1:{port}: {ex.Message}");
    return 1;
}

Log("OK", $"listening on ws://127.0.0.1:{port}  (token file: {tokenPath})");
ShowHelp();
Log("ST", Status());

// Optional remote control: characters appended to the --keys file are handled like key presses.
if (keysPath != null)
{
    Log("OK", $"also reading keys appended to {keysPath}");
    _ = Task.Run(async () =>
    {
        long pos = File.Exists(keysPath) ? new FileInfo(keysPath).Length : 0;
        while (!quit.IsCancellationRequested)
        {
            await Task.Delay(200);
            if (!File.Exists(keysPath)) continue;
            long length = new FileInfo(keysPath).Length;
            if (length < pos) pos = 0;
            if (length == pos) continue;
            string text;
            using (var fs = new FileStream(keysPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                fs.Seek(pos, SeekOrigin.Begin);
                var bytes = new byte[length - pos];
                fs.ReadExactly(bytes);
                text = Encoding.UTF8.GetString(bytes);
                pos = length;
            }
            foreach (var ch in text) await HandleKeyAsync(ch);
        }
    });
}

if (Console.IsInputRedirected)
{
    string? line;
    while (!quit.IsCancellationRequested && (line = await Console.In.ReadLineAsync()) != null)
        foreach (var ch in line) await HandleKeyAsync(ch);
    if (!quit.IsCancellationRequested) await Task.Delay(Timeout.Infinite, quit.Token).ContinueWith(_ => { });
}
else
{
    try
    {
        while (!quit.IsCancellationRequested)
        {
            if (!Console.KeyAvailable) { await Task.Delay(50); continue; }
            await HandleKeyAsync(Console.ReadKey(true).KeyChar);
        }
    }
    catch (InvalidOperationException)
    {
        // No usable console (started hidden from the Run key): keep serving until stopped.
        await Task.Delay(Timeout.Infinite, quit.Token).ContinueWith(_ => { });
    }
}

await app.StopAsync();
return 0;

sealed class Meeting
{
    public bool InMeeting, Muted, VideoOn = true, Sharing, ChatOpen;
    public int Unread;
    public string? Token;
    public DateTime LastBridgeUtc = DateTime.MinValue;
    public bool BridgeControl;
}

sealed class Client(WebSocket socket)
{
    static int next;
    public int Id { get; } = Interlocked.Increment(ref next);
    public WebSocket Socket { get; } = socket;
    public SemaphoreSlim Gate { get; } = new(1, 1);
    public volatile bool Paired;
}
