# READ-ONLY: which Telemost top-level windows exist right now and what UI Automation says about them
# (offscreen flag, window visual state), so the bridge can tell "normal call", "screen sharing" and "no call".
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$cls = [System.Windows.Automation.AutomationElement]::ClassNameProperty
foreach ($name in 'Telemost::TelemostWindowTelemes', 'MiniConferenceWindow', 'ScreenHUD', 'StartScreencastDialog') {
    $found = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition($cls, $name)))
    "{0,-34} count={1}" -f $name, $found.Count
    foreach ($w in $found) {
        $c = $w.Current
        $state = ''
        $p = $null
        if ($w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$p)) { $state = "visualState=$($p.Current.WindowVisualState) interactionState=$($p.Current.WindowInteractionState)" }
        $kids = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition).Count
        "    title='{0}' offscreen={1} hwnd=0x{2:X} descendants={3} {4}" -f $c.Name, $c.IsOffscreen, $c.NativeWindowHandle, $kids, $state
    }
}
