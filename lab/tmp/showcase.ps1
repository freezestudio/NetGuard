Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class S {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr r, IntPtr hr, uint f);
  [DllImport("dwmapi.dll")] public static extern int DwmFlush();
  public static List<IntPtr> All() { var r=new List<IntPtr>(); EnumWindows((h,l)=>{ if(IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowText(h,sb,512); return sb.ToString(); }
  public static IntPtr Find(string like) { foreach (var h in All()) if (Text(h).Contains(like)) return h; return IntPtr.Zero; }
}
'@
Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
Start-Process 'C:\NetGuard\NetGuardUI.exe' -ArgumentList '--password1'
Start-Sleep 5
$h = [S]::Find('NetGuard - ')
if ($h -eq [IntPtr]::Zero) { 'window not found'; exit 1 }
[S]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1350, 720, 0x0040) | Out-Null
[S]::ShowWindow($h, 9) | Out-Null
[S]::SetForegroundWindow($h) | Out-Null
[S]::RedrawWindow($h, [IntPtr]::Zero, [IntPtr]::Zero, 0x0085) | Out-Null  # INVALIDATE|UPDATENOW|ALLCHILDREN
[void][S]::DwmFlush()
Start-Sleep 2
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
$bmp.Save('C:\NetGuard\showcase.png', [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
$r = New-Object System.Drawing.Rectangle
'showcase done'
