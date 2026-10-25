# READ-ONLY UI Automation dump of a window: control type, name, automation id, class, enabled/offscreen and,
# where a Toggle/Window pattern exists, its current state. It never invokes, toggles, focuses or types anything.
param(
    [Parameter(Mandatory)][string]$Hwnd,        # e.g. 0xF016BE
    [int]$MaxNodes = 500,
    [int]$MaxDepth = 16,
    [int]$IdLen = 40,
    [string]$Only = ''     # when set, print only lines whose text matches this regex
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$h = [IntPtr][Convert]::ToInt64($Hwnd, 16)
$root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$script:count = 0
$sw = [Diagnostics.Stopwatch]::StartNew()

function Clip([string]$s, [int]$n = 70) { if ($null -eq $s) { return '' } ; $s = $s -replace '\s+', ' '; if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s } }

function Walk($el, [int]$depth) {
    if ($script:count -ge $MaxNodes -or $depth -gt $MaxDepth -or $sw.Elapsed.TotalSeconds -gt 25) { return }
    $script:count++
    $c = $el.Current
    $extra = ''
    $pat = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pat)) {
        $extra += " toggle=$($pat.Current.ToggleState)"
    }
    $pat = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pat)) {
        $extra += " value='$(Clip $pat.Current.Value 40)'"
    }
    $type = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
    $ind = ' ' * ($depth * 2)
    $r = $c.BoundingRectangle
    $patterns = ($el.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName -replace 'PatternIdentifiers.Pattern', '' }) -join ','
    $line = "{0}{1} '{2}' id='{3}' class='{4}' enabled={5} offscreen={6} rect={7}x{8}@{9},{10} patterns=[{11}]{12}" -f $ind, $type, (Clip $c.Name), (Clip $c.AutomationId $IdLen), (Clip $c.ClassName 40), $c.IsEnabled, $c.IsOffscreen, [int]$r.Width, [int]$r.Height, [int]$r.X, [int]$r.Y, $patterns, $extra
    if ($Only -eq '' -or $line -match $Only) { $line }
    $child = $walker.GetFirstChild($el)
    while ($null -ne $child) {
        Walk $child ($depth + 1)
        if ($script:count -ge $MaxNodes) { break }
        $child = $walker.GetNextSibling($child)
    }
}

Walk $root 0
"--- $($script:count) nodes in $([int]$sw.Elapsed.TotalSeconds) s (limit $MaxNodes) ---"
