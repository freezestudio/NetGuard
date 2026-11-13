Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class F2 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static List<IntPtr> All() { var r=new List<IntPtr>(); EnumWindows((h,l)=>{ if(IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowText(h,sb,512); return sb.ToString(); }
}
'@
[void][F2]::SetProcessDPIAware()
$ui = [IntPtr]::Zero
foreach ($h in [F2]::All()) {
  $t = [F2]::Text($h)
  if ($t -like '*cmd*') { [void][F2]::ShowWindow($h, 6); "minimized cmd: $t" }
  elseif ($t -like 'NetGuard - *' -and $ui -eq [IntPtr]::Zero) { $ui = $h }
}
if ($ui -ne [IntPtr]::Zero) {
  [void][F2]::SetWindowPos($ui, [IntPtr]::Zero, 4, 4, 1350, 840, 0x0040)
  [void][F2]::ShowWindow($ui, 5)
  [void][F2]::SetForegroundWindow($ui)
}
# 轻微移动鼠标，促使画面刷新
[void][F2]::SetCursorPos(760, 420); Start-Sleep -Milliseconds 250; [void][F2]::SetCursorPos(780, 440)
Start-Sleep 2
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
$bmp.Save('C:\NetGuard\final-screen.png', [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
'final arranged'
