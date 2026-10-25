# EXPERIMENT (changes the camera state in the live call, then restores it):
# compares TogglePattern.Toggle() with InvokePattern.Invoke() on the camera check box and watches the Windows
# webcam-usage record to see whether the camera really starts/stops.
# Usage: pwsh -File camera-invoke-test.ps1 -Method Invoke|Toggle
param([ValidateSet('Invoke', 'Toggle')][string]$Method = 'Invoke')

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$consentKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged\C:#Program Files#Yandex#YandexTelemost#YandexTelemost.exe'
function Webcam {
    $k = Get-ItemProperty $consentKey
    $stop = if ($k.LastUsedTimeStop -eq 0) { 'IN USE' } else { [DateTime]::FromFileTime($k.LastUsedTimeStop).ToString('HH:mm:ss') }
    'webcam record: start={0} stop={1}' -f [DateTime]::FromFileTime($k.LastUsedTimeStart).ToString('HH:mm:ss'), $stop
}

$cls = [System.Windows.Automation.AutomationElement]::ClassNameProperty
$win = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst('Children', (New-Object System.Windows.Automation.PropertyCondition($cls, 'Telemost::TelemostWindowTelemes')))
if (-not $win) { 'no call window'; return }
$cam = $win.FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox))) |
    Where-Object { $_.Current.AutomationId.EndsWith('.cameraButton') } | Select-Object -First 1
if (-not $cam) { 'camera button not found'; return }
$toggle = $cam.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)

function State { 'checkbox: ' + $(if ($toggle.Current.ToggleState -eq 'On') { 'On (camera OFF)' } else { 'Off (camera ON)' }) }
function Press {
    if ($Method -eq 'Invoke') { $cam.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } else { $toggle.Toggle() }
}

"{0:HH:mm:ss} method={1}" -f (Get-Date), $Method
"{0:HH:mm:ss} before:  {1}   {2}" -f (Get-Date), (State), (Webcam)

# Bring the check box to "camera ON" (Off) first, then watch the webcam record.
if ($toggle.Current.ToggleState -eq 'On') { Press; Start-Sleep -Milliseconds 800; "{0:HH:mm:ss} pressed -> {1}" -f (Get-Date), (State) }
else {
    # Already "ON" in the UI (possibly without a real camera): switch off and on again so the app handles a real "on".
    Press; Start-Sleep -Milliseconds 800; "{0:HH:mm:ss} pressed -> {1}" -f (Get-Date), (State)
    Press; Start-Sleep -Milliseconds 800; "{0:HH:mm:ss} pressed -> {1}" -f (Get-Date), (State)
}
Start-Sleep -Seconds 5
"{0:HH:mm:ss} after 5 s: {1}   {2}" -f (Get-Date), (State), (Webcam)

# Restore: camera OFF.
if ($toggle.Current.ToggleState -eq 'Off') { Press; Start-Sleep -Milliseconds 1500 }
"{0:HH:mm:ss} restored: {1}   {2}" -f (Get-Date), (State), (Webcam)
