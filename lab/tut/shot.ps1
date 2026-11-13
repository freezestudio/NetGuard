param(
    [string]$Name = 'shot',
    [string]$TitleLike = '',
    [switch]$FullScreen,
    [string]$OutDir = 'C:\NetGuard\tut\shots'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$log = 'C:\NetGuard\tut\shots.log'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class TShot {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public static IntPtr Find(string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            string t = sb.ToString();
            if (t.Length > 0 && t.IndexOf(title, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Say($m) { "$(Get-Date -Format 'HH:mm:ss.fff')  $m" | Out-File $log -Append -Encoding utf8 }

try {
    if ($FullScreen) {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $x = $vs.Left; $y = $vs.Top; $w = $vs.Width; $h = $vs.Height
    } else {
        $hw = [TShot]::Find($TitleLike)
        if ($hw -eq [IntPtr]::Zero) { Say "MISS $Name (title like '$TitleLike')"; exit 1 }
        [void][TShot]::ShowWindow($hw, 9)
        [void][TShot]::SetForegroundWindow($hw)
        Start-Sleep -Milliseconds 500
        $r = New-Object TShot+RECT
        [void][TShot]::GetWindowRect($hw, [ref]$r)
        $x = $r.Left; $y = $r.Top; $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    }
    $vs2 = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($x -lt $vs2.Left) { $x = $vs2.Left }
    if ($y -lt $vs2.Top) { $y = $vs2.Top }
    if ($x + $w -gt $vs2.Right) { $w = $vs2.Right - $x }
    if ($y + $h -gt $vs2.Bottom) { $h = $vs2.Bottom - $y }
    if ($w -le 0 -or $h -le 0) { Say "BADRECT $Name"; exit 1 }

    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
    $path = Join-Path $OutDir ($Name + '.png')
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Say "OK $Name ${w}x${h} -> $path"
} catch {
    Say "ERR $Name : $($_.Exception.Message)"
    exit 1
}
exit 0
