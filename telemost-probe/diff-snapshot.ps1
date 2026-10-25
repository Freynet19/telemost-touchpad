# READ-ONLY: takes a new snapshot of the Telemost windows and call-window UI Automation tree and prints
# how it differs from the saved baseline (uia-before.txt / windows-before.txt). Rects are ignored.
param(
    [Parameter(Mandatory)][string]$Name,          # snapshot name, e.g. sharing
    [string]$Hwnd = '0xF016BE'
)

$dir = $PSScriptRoot

function Strip([string]$line) {
    $line = $line -replace 'rect=\S+ ', ''
    $line -replace 'TApplication\.TelemostWindowTelemes\.centralwidget\.Telemost::QWidgetRestrictedToDeleteLater\.MainConferenceView\.', '<MCV>.'
}
function WindowKey([string]$line) {
    if ($line -match "visible=(\w+) minimized=(\w+) rect=\S+ class='([^']*)' title='([^']*)'") {
        "visible=$($Matches[1]) min=$($Matches[2]) class=$($Matches[3]) title=$($Matches[4])"
    } else { $line }
}

& pwsh -NoProfile -File (Join-Path $dir 'probe-windows.ps1') 2>&1 | Where-Object { $_ -match '^hwnd' } | Set-Content (Join-Path $dir "windows-$Name.txt")
& pwsh -NoProfile -File (Join-Path $dir 'probe-uia.ps1') -Hwnd $Hwnd -MaxNodes 800 -IdLen 300 2>&1 | Set-Content (Join-Path $dir "uia-$Name.txt")

'--- windows vs baseline ---'
Compare-Object ((Get-Content (Join-Path $dir 'windows-before.txt')) | ForEach-Object { WindowKey $_ }) `
               ((Get-Content (Join-Path $dir "windows-$Name.txt")) | ForEach-Object { WindowKey $_ }) |
    ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject }

'--- call window tree vs baseline ---'
Compare-Object ((Get-Content (Join-Path $dir 'uia-before.txt')) | ForEach-Object { Strip $_ }) `
               ((Get-Content (Join-Path $dir "uia-$Name.txt")) | ForEach-Object { Strip $_ }) |
    ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject }
