# Sends Teams-API commands to the running fake-teams as a paired client (what Dell Optimizer does when a
# touchpad button is pressed). Example: pwsh -File send-command.ps1 -Actions unmute,unmute,mute -DelayMs 150
param(
    [Parameter(Mandatory)][string[]]$Actions,
    [int]$DelayMs = 200,
    [int]$Port = 8124,
    [int]$ListenMs = 2500   # how long to keep listening for replies after the last command
)

$Actions = $Actions | ForEach-Object { $_ -split ',' } | Where-Object { $_ }   # `pwsh -File` passes "a,b" as one string

$tokenFile = Join-Path $PSScriptRoot "bin\Release\net10.0\token-$Port.txt"
$token = if (Test-Path $tokenFile) { (Get-Content $tokenFile -Raw).Trim() } else { '' }

$ws = [Net.WebSockets.ClientWebSocket]::new()
$q = 'protocol-version=2.0.0&app=Command%20Tester&manufacturer=Test&device=Dell%20Collaboration%20Touchpad&app-version=0.0'
if ($token) { $q += "&token=$token" }
$null = $ws.ConnectAsync([Uri]"ws://127.0.0.1:${Port}?${q}", [Threading.CancellationToken]::None).GetAwaiter().GetResult()

$buf = [byte[]]::new(8192)
$pending = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None)
function Pump {
    # print any replies that already arrived, without cancelling the outstanding receive
    while ($pending.IsCompleted) {
        $r = $pending.GetAwaiter().GetResult()
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
        $j = $text | ConvertFrom-Json
        if ($j.meetingUpdate -and $j.meetingUpdate.meetingState) {
            $s = $j.meetingUpdate.meetingState
            "{0:HH:mm:ss.fff}   <- state: mic={1} camera={2}" -f (Get-Date), $(if ($s.isMuted) { 'MUTED' } else { 'live' }), $(if ($s.isVideoOn) { 'on' } else { 'off' })
        } elseif ($j.response) { "{0:HH:mm:ss.fff}   <- ack (requestId {1})" -f (Get-Date), $j.requestId }
        elseif ($j.errorMsg) { "{0:HH:mm:ss.fff}   <- error: {1}" -f (Get-Date), $j.errorMsg }
        $script:pending = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None)
    }
}

$id = 900
foreach ($a in $Actions) {
    $id++
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{ action = $a; requestId = $id } | ConvertTo-Json -Compress))
    "{0:HH:mm:ss.fff} -> {1}" -f (Get-Date), $a
    $null = $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $until = [DateTime]::UtcNow.AddMilliseconds($DelayMs)
    while ([DateTime]::UtcNow -lt $until) { Pump; Start-Sleep -Milliseconds 20 }
}
$until = [DateTime]::UtcNow.AddMilliseconds($ListenMs)
while ([DateTime]::UtcNow -lt $until) { Pump; Start-Sleep -Milliseconds 20 }
$ws.Abort()
