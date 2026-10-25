# EXPERIMENT (changes the camera in the live call while the screen is being shared, then restores it):
# opens the "..." menu of Telemost's mini window, flips the "Video" item with a real click (InvokePattern),
# watches whether the menu closes by itself, closes it with WindowPattern.Close() if not, then flips the camera back.
# It only ever touches: the "..." button of the mini window, the "Video" menu item, and the menu window itself.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$UIA = [System.Windows.Automation.AutomationElement]
$Cls = $UIA::ClassNameProperty

$consentKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged\C:#Program Files#Yandex#YandexTelemost#YandexTelemost.exe'
function Webcam {
    $k = Get-ItemProperty $consentKey
    $stop = if ($k.LastUsedTimeStop -eq 0) { 'IN USE' } else { [DateTime]::FromFileTime($k.LastUsedTimeStop).ToString('HH:mm:ss') }
    'webcam record: start={0} stop={1}' -f [DateTime]::FromFileTime($k.LastUsedTimeStart).ToString('HH:mm:ss'), $stop
}
function Log($m) { Write-Host ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m) }   # Write-Host: must not leak into return values
function Top($class) { $UIA::RootElement.FindFirst('Children', (New-Object System.Windows.Automation.PropertyCondition($Cls, $class))) }
function WaitTop($class, [int]$ms = 1500, [bool]$gone = $false) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.ElapsedMilliseconds -lt $ms) {
        $e = Top $class
        if ($gone -and -not $e) { return $true }
        if (-not $gone -and $e) { return $e }
        Start-Sleep -Milliseconds 40
    }
    if ($gone) { return $false } else { return $null }
}
function MenuButton {
    $mini = Top 'MiniConferenceWindow'
    if (-not $mini) { return $null }
    $buttons = $mini.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.AutomationId.EndsWith('.footerWidget.SimplePanelButton') } |
        Sort-Object { $_.Current.BoundingRectangle.X }
    if (@($buttons).Count -ne 3) { return $null }
    return @($buttons)[2]
}
function VideoItem($menu) {
    $menu.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.AutomationId.EndsWith('.cameraMenuItem') } | Select-Object -First 1
}
function CloseMenu {
    $m = Top 'MiniControlPanelMenuWidget'
    if (-not $m) { Log 'menu already closed by itself'; return 'closed-by-itself' }
    Log 'menu still open -> WindowPattern.Close() on the menu window only'
    ($m.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    if (WaitTop 'MiniControlPanelMenuWidget' 1500 $true) { Log 'menu closed by Close()'; return 'closed-by-Close' }
    Log 'menu STILL open after Close() - leaving it for the user'; return 'still-open'
}
# opens the menu, flips Video if $flip, returns @{ before; menuClose }
function Session([bool]$flip) {
    $btn = MenuButton
    if (-not $btn) { throw 'mini window footer (3 buttons) not found - is the screen being shared?' }
    ($btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
    $menu = WaitTop 'MiniControlPanelMenuWidget' 1500
    if (-not $menu) { throw 'menu did not appear' }
    $item = VideoItem $menu
    if (-not $item) { throw 'Video menu item not found' }
    $state = ($item.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState
    Log ("menu open. Video item: {0}" -f $(if ($state -eq 'On') { 'On (camera OFF)' } else { 'Off (camera ON)' }))
    if ($flip) {
        ($item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
        Log 'Video item clicked (Invoke)'
        Start-Sleep -Milliseconds 700
    }
    $close = CloseMenu
    return @{ before = $state; menuClose = $close }
}

Log ('start. ' + (Webcam))
if (-not (Top 'ScreenHUD')) { Log 'ScreenHUD not present: not in sharing mode, aborting'; return }

$a = Session $true        # flip once
Start-Sleep -Seconds 3
Log ('after flip. ' + (Webcam))
$b = Session $true        # read the new state and flip back
Start-Sleep -Milliseconds 1500
Log ('after restore. ' + (Webcam))
$c = Session $false       # final read only
Log ("SUMMARY: initial camera checkbox={0}, after flip={1}, after restore={2}; menu close behaviour: {3}/{4}/{5}" -f $a.before, $b.before, $c.before, $a.menuClose, $b.menuClose, $c.menuClose)
