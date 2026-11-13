Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class Win {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  public static List<IntPtr> All() {
    var r = new List<IntPtr>();
    EnumWindows((h,l) => { if (IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero);
    return r;
  }
  public static string Text(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
}
'@
$ws = [Win]::All() | ForEach-Object { [pscustomobject]@{ H = $_; T = [Win]::Text($_) } }
$ws | Where-Object { $_.T } | ForEach-Object { "win: " + $_.T }
# 把用户留下的空白 cmd 窗口最小化，避免挡住界面
$ws | Where-Object { $_.T -like '*cmd.exe*' } | ForEach-Object { [Win]::ShowWindow($_.H, 6) | Out-Null; 'minimized: ' + $_.T }
# 管理界面置前并缩放
$ui = $ws | Where-Object { $_.T -like '*NetGuard*' } | Select-Object -First 1
if (-not $ui) { Start-Process 'C:\NetGuard\NetGuardUI.exe' -ArgumentList '--password1'; Start-Sleep 6; $ws = [Win]::All() | ForEach-Object { [pscustomobject]@{ H = $_; T = [Win]::Text($_) } }; $ui = $ws | Where-Object { $_.T -like '*NetGuard*' } | Select-Object -First 1 }
if ($ui) {
  [Win]::SetWindowPos($ui.H, [IntPtr]::Zero, 0, 0, 1360, 730, 0x0040) | Out-Null
  [Win]::ShowWindow($ui.H, 9) | Out-Null
  [Win]::SetForegroundWindow($ui.H) | Out-Null
  'ui: ' + $ui.T
} else { 'ui not found' }
Start-Sleep 3
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
$bmp.Save('C:\NetGuard\arrange.png', [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
'arranged'
