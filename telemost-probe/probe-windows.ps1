# READ-ONLY: lists top-level windows of Telemost processes and the Windows privacy consent-store entries
# (camera/microphone "last used" timestamps). Sends no input and changes nothing.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WinList
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    public static List<string> ForPids(HashSet<uint> pids)
    {
        var res = new List<string>();
        EnumWindows((h, l) =>
        {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (!pids.Contains(pid)) return true;
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            RECT r; GetWindowRect(h, out r);
            res.Add(string.Format("hwnd=0x{0:X} pid={1} visible={2} minimized={3} rect={4}x{5}@{6},{7} class='{8}' title='{9}'",
                h.ToInt64(), pid, IsWindowVisible(h), IsIconic(h), r.R - r.L, r.B - r.T, r.L, r.T, c, t));
            return true;
        }, IntPtr.Zero);
        return res;
    }
}
'@

$pids = [Collections.Generic.HashSet[uint32]]::new()
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'Telemost' } | ForEach-Object { [void]$pids.Add([uint32]$_.ProcessId) }
Write-Output "--- top-level windows of Telemost processes ($($pids.Count) pids) ---"
[WinList]::ForPids($pids)

Write-Output "`n--- privacy consent store (Telemost entries) ---"
function FileTimeToLocal($v) { if ($v -eq 0) { return '0 (still in use / never stopped)' } ; [DateTime]::FromFileTime($v).ToString('yyyy-MM-dd HH:mm:ss') }
foreach ($cap in 'webcam', 'microphone') {
    $root = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$cap\NonPackaged"
    Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object PSChildName -match 'Telemost' | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        "{0,-10} {1}" -f $cap, $_.PSChildName
        "           Value={0}  Start={1}  Stop={2}" -f $p.Value, (FileTimeToLocal $p.LastUsedTimeStart), (FileTimeToLocal $p.LastUsedTimeStop)
    }
}
"now: " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
