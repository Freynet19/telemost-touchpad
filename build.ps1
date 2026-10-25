<#
.SYNOPSIS
    Builds the two programs and assembles an installable folder (dist\ by default).

.DESCRIPTION
    dist\ gets: fake-teams\, telemost-bridge\ (framework-dependent publish), the scripts from scripts\ and a
    VERSION.txt describing what it was built on. Then run dist\install.ps1 (preview with -WhatIf first).
    Needs the .NET 10 SDK on Windows.

    -Zip additionally writes dist.zip next to the folder.
#>
[CmdletBinding()]
param(
    [string]$Output,
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Output) { $Output = Join-Path $root 'dist' }

if (Test-Path $Output) {
    if (-not (Test-Path (Join-Path $Output 'VERSION.txt'))) {
        throw "$Output exists and does not look like an earlier build (no VERSION.txt). Remove it yourself or pass another -Output."
    }
    Remove-Item -LiteralPath $Output -Recurse -Force
}
New-Item -ItemType Directory -Path $Output | Out-Null

foreach ($name in 'fake-teams', 'telemost-bridge') {
    Write-Host "Publishing $name ..."
    & dotnet publish (Join-Path $root "$name\$name.csproj") -c Release -o (Join-Path $Output $name)
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $name" }
}
Copy-Item -Path (Join-Path $root 'scripts\*.ps1') -Destination $Output

# What this build was made (and can be expected to work) with.
$optimizer = (Get-AppxPackage -Name 'DellInc.DellOptimizer' -ErrorAction SilentlyContinue | Select-Object -First 1).Version
$telemostExe = 'C:\Program Files\Yandex\YandexTelemost\YandexTelemost.exe'
$telemost = if (Test-Path $telemostExe) { (Get-Item $telemostExe).VersionInfo.FileVersion } else { 'not installed' }
$commit = try { (& git -C $root rev-parse --short HEAD 2>$null) } catch { $null }
@"
Telemost <-> Dell Collaboration Touchpad bridge - build

Built:       $(Get-Date -Format 'yyyy-MM-dd HH:mm')
Commit:      $(if ($commit) { $commit } else { 'n/a' })
Built on:    Dell Optimizer $(if ($optimizer) { $optimizer } else { 'not found' }), Yandex Telemost $telemost,
             Windows $([Environment]::OSVersion.Version), .NET SDK $(& dotnet --version)

Install (per user, no administrator):  powershell -ExecutionPolicy Bypass -File install.ps1 [-WhatIf]
Remove:                                powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-WhatIf]
"@ | Set-Content -Path (Join-Path $Output 'VERSION.txt') -Encoding UTF8

if ($Zip) {
    $zipPath = "$Output.zip"
    Compress-Archive -Path (Join-Path $Output '*') -DestinationPath $zipPath -Force
    Write-Host "Wrote $zipPath"
}
Write-Host "Done: $Output"
