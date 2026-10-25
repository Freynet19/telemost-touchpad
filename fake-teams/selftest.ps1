# Starts fake-teams on a spare port, then talks to it the way Dell Optimizer would and checks the replies.
# Usage: pwsh -File selftest.ps1 [-Port 18124]
param([int]$Port = 18124)

$ErrorActionPreference = 'Stop'
$dll = Join-Path $PSScriptRoot 'bin\Release\net10.0\fake-teams.dll'

$psi = [Diagnostics.ProcessStartInfo]::new('dotnet', "`"$dll`" --port $Port")
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$server = [Diagnostics.Process]::Start($psi)
$server.StandardInput.AutoFlush = $true
$serverOutput = $server.StandardOutput.ReadToEndAsync()   # collected, printed at the end

$script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:fail++ }
}

function Connect([string]$token = '') {
    $ws = [Net.WebSockets.ClientWebSocket]::new()
    $q = "protocol-version=2.0.0&app=Dell%20Optimizer&manufacturer=Dell%20Inc.&device=Dell%20Collaboration%20Touchpad&app-version=4.2.4.0"
    if ($token) { $q += "&token=$token" }
    $null = $ws.ConnectAsync([Uri]"ws://127.0.0.1:${Port}?${q}", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    return $ws
}

function Recv($ws, [int]$timeoutMs = 3000) {
    $cts = [Threading.CancellationTokenSource]::new($timeoutMs)
    $buf = [byte[]]::new(8192)
    try {
        $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).GetAwaiter().GetResult()
        return [Text.Encoding]::UTF8.GetString($buf, 0, $r.Count) | ConvertFrom-Json
    } catch { return $null }
}

function Send($ws, [hashtable]$msg) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($msg | ConvertTo-Json -Compress -Depth 5))
    $null = $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

# Reads messages until one has a meetingUpdate (skipping acks / tokenRefresh), returns it.
function RecvUpdate($ws, [int]$timeoutMs = 3000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $m = Recv $ws 500
        if ($m -and $m.meetingUpdate) { return $m.meetingUpdate }
    }
    return $null
}

try {
    Start-Sleep -Milliseconds 1500   # let Kestrel come up
    $ws = Connect
    $u = RecvUpdate $ws
    Check 'unpaired connect: meetingState absent' ($u -and -not $u.PSObject.Properties['meetingState'])
    Check 'unpaired, no meeting: canPair=false' ($u -and $u.meetingPermissions.canPair -eq $false)

    $server.StandardInput.WriteLine('j')   # join meeting
    $u = RecvUpdate $ws
    Check 'join meeting (key j): canPair=true while unpaired' ($u -and $u.meetingPermissions.canPair -eq $true)

    Send $ws @{ action = 'toggle-mute'; requestId = 1 }
    $m = Recv $ws
    Check 'media command before pairing is refused' ($m -and $m.errorMsg -eq 'Pairing required')

    Send $ws @{ action = 'pair'; requestId = 2 }
    $m = Recv $ws
    $token = $m.tokenRefresh
    Check 'pair: tokenRefresh received' ([bool]$token)
    $u = RecvUpdate $ws
    Check 'pair: paired update has isInMeeting=true' ($u -and $u.meetingState.isInMeeting -eq $true)

    Send $ws @{ action = 'toggle-mute'; requestId = 3 }
    $u = RecvUpdate $ws
    Check 'toggle-mute -> isMuted=true' ($u -and $u.meetingState.isMuted -eq $true)

    Send $ws @{ action = 'toggle-video'; requestId = 4 }
    $u = RecvUpdate $ws
    Check 'toggle-video -> isVideoOn=false' ($u -and $u.meetingState.isVideoOn -eq $false)

    Send $ws @{ action = 'toggle-ui'; requestId = 5; parameters = @{ type = 'share-tray' } }
    $u = RecvUpdate $ws
    Check 'toggle-ui share-tray -> isSharing=true' ($u -and $u.meetingState.isSharing -eq $true)

    Send $ws @{ action = 'stop-sharing'; requestId = 6 }
    $u = RecvUpdate $ws
    Check 'stop-sharing -> isSharing=false' ($u -and $u.meetingState.isSharing -eq $false)

    $server.StandardInput.WriteLine('c')   # incoming chat message
    $u = RecvUpdate $ws
    Check 'incoming chat (key c) -> numUnreadMessages=1' ($u -and $u.meetingState.numUnreadMessages -eq 1)

    Send $ws @{ action = 'toggle-ui'; requestId = 7; parameters = @{ type = 'chat' } }
    $u = RecvUpdate $ws
    Check 'toggle-ui chat clears unread' ($u -and $u.meetingState.numUnreadMessages -eq 0)

    $ws2 = Connect $token
    $u = RecvUpdate $ws2
    Check 'reconnect with saved token is paired immediately' ($u -and $u.meetingState.isInMeeting -eq $true)

    # telemost-bridge feed: real state overrides the simulation and touchpad commands become no-ops
    $body = '{"inMeeting":true,"muted":false,"videoOn":true,"chatOpen":true}'
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:${Port}/bridge/state" -ContentType 'application/json' -Body $body | Out-Null
    $u = RecvUpdate $ws2
    Check 'bridge feed -> isMuted=false, isVideoOn=true' ($u -and $u.meetingState.isMuted -eq $false -and $u.meetingState.isVideoOn -eq $true)

    Send $ws2 @{ action = 'mute'; requestId = 20 }
    $u = RecvUpdate $ws2
    Check 'touchpad mute is ignored while bridge is active (state unchanged)' ($u -and $u.meetingState.isMuted -eq $false)

    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:${Port}/bridge/state" -ContentType 'application/json' -Body '{"inMeeting":true,"muted":true,"videoOn":true,"chatOpen":true}' | Out-Null
    $u = RecvUpdate $ws2
    Check 'bridge change (muted in Telemost) reaches the client' ($u -and $u.meetingState.isMuted -eq $true)

    # control mode: touchpad mic/camera commands are queued for the bridge instead of being ignored
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:${Port}/bridge/state" -ContentType 'application/json' -Body '{"inMeeting":true,"muted":true,"videoOn":true,"chatOpen":true,"control":true}' | Out-Null
    Send $ws2 @{ action = 'unmute'; requestId = 21 }
    $ack = Recv $ws2
    Check 'control mode: touchpad unmute is acknowledged' ($ack -and $ack.response -eq 'Success')
    $cmds = Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/bridge/commands?wait=2000"
    Check 'control mode: unmute is queued for the bridge' (@($cmds).Count -eq 1 -and $cmds[0].action -eq 'unmute')
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:${Port}/bridge/state" -ContentType 'application/json' -Body '{"inMeeting":true,"muted":false,"videoOn":true,"chatOpen":true,"control":true,"force":true}' | Out-Null
    $u = RecvUpdate $ws2
    Check 'control mode: state pushed by the bridge after the command (isMuted=false)' ($u -and $u.meetingState.isMuted -eq $false)
    Send $ws2 @{ action = 'toggle-ui'; requestId = 22; parameters = @{ type = 'chat' } }
    $ack = Recv $ws2
    $cmds = Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/bridge/commands?wait=2000"
    Check 'control mode: chat toggle is forwarded with its parameter' (@($cmds).Count -eq 1 -and $cmds[0].action -eq 'toggle-ui' -and $cmds[0].param -eq 'chat')
    Send $ws2 @{ action = 'toggle-ui'; requestId = 23; parameters = @{ type = 'share-tray' } }
    $ack = Recv $ws2
    $cmds = Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/bridge/commands?wait=2000"
    Check 'control mode: share-tray is forwarded' (@($cmds).Count -eq 1 -and $cmds[0].param -eq 'share-tray')
    Send $ws2 @{ action = 'stop-sharing'; requestId = 24 }
    $ack = Recv $ws2
    $cmds = Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/bridge/commands?wait=2000"
    Check 'control mode: stop-sharing is forwarded' (@($cmds).Count -eq 1 -and $cmds[0].action -eq 'stop-sharing')
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:${Port}/bridge/state" -ContentType 'application/json' -Body '{"inMeeting":true,"muted":false,"videoOn":true,"chatOpen":true,"control":true,"sharing":true,"unread":3}' | Out-Null
    $u = RecvUpdate $ws2
    Check 'bridge reports sharing and unread messages' ($u -and $u.meetingState.isSharing -eq $true -and $u.meetingState.numUnreadMessages -eq 3)
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:${Port}/bridge/state" -ContentType 'application/json' -Body '{"inMeeting":true,"muted":false,"videoOn":true,"chatOpen":true,"control":true,"sharing":false,"unread":0}' | Out-Null
    $u = RecvUpdate $ws2
    Check 'bridge reports sharing stopped' ($u -and $u.meetingState.isSharing -eq $false)
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:${Port}/bridge/state" -ContentType 'application/json' -Body '{"inMeeting":false,"muted":false,"videoOn":true,"chatOpen":false}' | Out-Null
    $u = RecvUpdate $ws2
    Check 'bridge: call ended -> isInMeeting=false' ($u -and $u.meetingState.isInMeeting -eq $false)

    $server.StandardInput.WriteLine('r')   # revoke token
    # The first client still has the bridge updates queued; skip them and look for the unpaired one.
    $u = $null
    for ($i = 0; $i -lt 12 -and -not $u; $i++) {
        $m = Recv $ws 2000
        if (-not $m) { break }
        if ($m.meetingUpdate -and -not $m.meetingUpdate.PSObject.Properties['meetingState']) { $u = $m.meetingUpdate }
    }
    Check 'revoke (key r) -> existing client becomes unpaired' ($u -and -not $u.PSObject.Properties['meetingState'])

    Send $ws @{ action = 'bogus'; requestId = 8 }
    $m = Recv $ws
    Check 'unpaired client is refused even for unknown action' ($m -and $m.errorMsg)

    $ws.Dispose(); $ws2.Dispose()
} finally {
    $server.StandardInput.WriteLine('q')
    if (-not $server.WaitForExit(3000)) { $server.Kill() }
    Write-Host "`n--- server log ---"
    $serverOutput.GetAwaiter().GetResult() | Write-Host
}

if ($script:fail -eq 0) { Write-Host "`nALL CHECKS PASSED" -ForegroundColor Green } else { Write-Host "`n$script:fail CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
