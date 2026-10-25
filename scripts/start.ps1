# Starts the Telemost <-> Dell Collaboration Touchpad bridge: fake-teams (pretends to be Teams for Dell Optimizer)
# and telemost-bridge (reads/controls Yandex Telemost through UI Automation). Both run hidden; logs in .\logs.
# Safe to run more than once: a program that is already running is not started again.
$root = $PSScriptRoot
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

function Start-Hidden([string]$name, [string]$exe, [string]$arguments) {
    if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return }
    $out = Join-Path $logs "$name.log"
    $err = Join-Path $logs "$name.err.log"
    foreach ($f in $out, $err) { if (Test-Path $f) { Move-Item $f "$f.old" -Force } }   # keep only the previous run
    $params = @{
        FilePath               = $exe
        WorkingDirectory       = Split-Path $exe
        WindowStyle            = 'Hidden'
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
    }
    if ($arguments) { $params.ArgumentList = $arguments }
    Start-Process @params
}

Start-Hidden 'fake-teams' (Join-Path $root 'fake-teams\fake-teams.exe') ''
Start-Sleep -Seconds 2
Start-Hidden 'telemost-bridge' (Join-Path $root 'telemost-bridge\telemost-bridge.exe') '--control'
