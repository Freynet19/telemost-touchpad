<#
.SYNOPSIS
    Installs (or reinstalls) the Telemost <-> Dell Collaboration Touchpad bridge for the current user.

.DESCRIPTION
    Copies the programs from this folder to %LOCALAPPDATA%\TelemostTouchpad, makes sure the registry pieces Dell
    Optimizer needs exist, registers the autostart and starts everything. Needs no administrator rights.
    Safe to run again: an existing pairing token and the logs in the target folder are kept.

    What it changes (all under HKCU / the target folder):
      * <Target>\fake-teams, <Target>\telemost-bridge, <Target>\start.ps1, <Target>\stop.ps1
      * HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams  (DisplayName=Teams; only created if missing)
      * HKCU\Software\Microsoft\Windows\CurrentVersion\Run\TelemostTouchpad

    Preview without changing anything:   .\install.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'TelemostTouchpad'),
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$teamsKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams'
$runValue = 'powershell.exe -NoProfile -WindowStyle Hidden -File "' + (Join-Path $Target 'start.ps1') + '"'

# --- prerequisites (warnings only) -------------------------------------------------------------------------
try { $runtimes = & dotnet --list-runtimes 2>$null } catch { $runtimes = @() }
foreach ($need in 'Microsoft.NETCore.App 10.', 'Microsoft.AspNetCore.App 10.', 'Microsoft.WindowsDesktop.App 10.') {
    if (-not ($runtimes | Where-Object { $_ -like "$need*" })) {
        Write-Warning "The .NET runtime '$need*' was not found. Install the .NET 10 Desktop Runtime and ASP.NET Core Runtime (x64)."
    }
}
$savedWhatIf = $WhatIfPreference
$WhatIfPreference = $false   # -WhatIf must not leak into the implicit Appx module import below
try { $optimizer = Get-AppxPackage -Name 'DellInc.DellOptimizer' -ErrorAction SilentlyContinue | Select-Object -First 1 }
finally { $WhatIfPreference = $savedWhatIf }
if ($optimizer) { Write-Host "Dell Optimizer $($optimizer.Version) found." } else { Write-Warning 'Dell Optimizer was not found; the touchpad buttons will not react.' }

# --- stop running copies -----------------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess('fake-teams, telemost-bridge', 'Stop running copies')) {
    Stop-Process -Name 'telemost-bridge', 'fake-teams' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

# --- files -------------------------------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($Target, 'Copy programs and scripts')) {
    New-Item -ItemType Directory -Force -Path $Target, (Join-Path $Target 'logs') | Out-Null
    foreach ($name in 'fake-teams', 'telemost-bridge') {
        Copy-Item -Path (Join-Path $here $name) -Destination $Target -Recurse -Force
    }
    Copy-Item -Path (Join-Path $here 'start.ps1'), (Join-Path $here 'stop.ps1') -Destination $Target -Force
}

# --- registry ----------------------------------------------------------------------------------------------
# Dell Optimizer only keeps trying to reach the Teams API while it believes Teams is installed, which it decides
# by the existence of this key (the content does not matter).
if (-not (Test-Path $teamsKey)) {
    if ($PSCmdlet.ShouldProcess($teamsKey, 'Create (DisplayName=Teams)')) {
        New-Item -Path $teamsKey -Force | Out-Null
        New-ItemProperty -Path $teamsKey -Name DisplayName -Value 'Teams' -PropertyType String | Out-Null
    }
} else {
    Write-Host 'Uninstall\Teams key already exists; left as is.'
}
if ($PSCmdlet.ShouldProcess("$runKey\TelemostTouchpad", 'Set autostart')) {
    New-ItemProperty -Path $runKey -Name 'TelemostTouchpad' -Value $runValue -PropertyType ExpandString -Force | Out-Null
}

# --- start -------------------------------------------------------------------------------------------------
if (-not $NoStart -and $PSCmdlet.ShouldProcess('start.ps1', 'Start now')) {
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-File', (Join-Path $Target 'start.ps1')
    Write-Host 'Started. Optimizer reconnects within ~30 seconds; see logs in' (Join-Path $Target 'logs')
}
if ($WhatIfPreference) { Write-Host 'WhatIf: nothing was changed.' }
