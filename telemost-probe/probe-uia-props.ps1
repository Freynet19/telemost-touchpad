# READ-ONLY: prints every property UI Automation exposes (Name, HelpText, Legacy IAccessible name/description,
# rectangle, Toggle state) for buttons/check boxes inside one window. Nothing is invoked, toggled or focused.
param([Parameter(Mandatory)][string]$Hwnd, [string]$IdMatch = '')

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][Convert]::ToInt64($Hwnd, 16))
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)

foreach ($el in $all) {
    $c = $el.Current
    $type = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
    if ($type -notin 'Button', 'CheckBox') { continue }
    if ($IdMatch -and $c.AutomationId -notmatch $IdMatch) { continue }
    $r = $c.BoundingRectangle
    $line = "{0} id=...{1} rect={2}x{3}@{4},{5} name='{6}' help='{7}'" -f $type, ($c.AutomationId -split '\.')[-1], [int]$r.Width, [int]$r.Height, [int]$r.X, [int]$r.Y, $c.Name, $c.HelpText
    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $line += " toggle=$($p.Current.ToggleState)" }
    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$p)) {
        $l = $p.Current
        $line += " legacy[name='$($l.Name)' desc='$($l.Description)' role=$($l.Role) state=$($l.State) action='$($l.DefaultAction)']"
    }
    $line
}
