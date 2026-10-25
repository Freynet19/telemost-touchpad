<#
.SYNOPSIS
    Removes the Telemost <-> Dell Collaboration Touchpad bridge for the current user.

.DESCRIPTION
    Removes the autostart entry, stops the programs and deletes the install folder. The
    HKCU\...\Uninstall\Teams key is removed only if it looks like the one install.ps1 created (a single value,
    DisplayName=Teams), so a real Teams installation is never touched.

    Not removed (needs administrator, optional): Dell Optimizer's own pairing record
        HKLM:\SOFTWARE\Dell\DellOptimizer\PData

    Preview without changing anything:   .\uninstall.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'TelemostTouchpad'),
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$teamsKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams'

if ($PSCmdlet.ShouldProcess("$runKey\TelemostTouchpad", 'Remove autostart')) {
    Remove-ItemProperty -Path $runKey -Name 'TelemostTouchpad' -ErrorAction SilentlyContinue
}
if ($PSCmdlet.ShouldProcess('fake-teams, telemost-bridge', 'Stop')) {
    Stop-Process -Name 'telemost-bridge', 'fake-teams' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}
if (-not $KeepFiles -and (Test-Path $Target) -and $PSCmdlet.ShouldProcess($Target, 'Delete folder')) {
    Remove-Item -Path $Target -Recurse -Force
}
if (Test-Path $teamsKey) {
    $item = Get-Item $teamsKey
    $values = @($item.GetValueNames() | Where-Object { $_ })
    $ours = ($values.Count -eq 1 -and $values[0] -eq 'DisplayName' -and $item.GetValue('DisplayName') -eq 'Teams' -and $item.SubKeyCount -eq 0)
    if ($ours -and $PSCmdlet.ShouldProcess($teamsKey, 'Remove (created by install.ps1)')) {
        Remove-Item -Path $teamsKey -Force
    } elseif (-not $ours) {
        Write-Host 'Uninstall\Teams key has other content; left as is.'
    }
}
if ($WhatIfPreference) { Write-Host 'WhatIf: nothing was changed.' }
