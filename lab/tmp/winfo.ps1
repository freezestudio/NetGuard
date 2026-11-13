Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class Q {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  public static List<IntPtr> All() { var r=new List<IntPtr>(); EnumWindows((h,l)=>{ if(IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowText(h,sb,512); return sb.ToString(); }
}
'@
Add-Type -AssemblyName System.Drawing
$h = [IntPtr]::Zero
foreach ($x in [Q]::All()) { if ([Q]::Text($x) -like 'NetGuard - *') { $h = $x; break } }
if ($h -eq [IntPtr]::Zero) { 'no ui'; exit 1 }
$wr = New-Object Q+RECT; [void][Q]::GetWindowRect($h, [ref]$wr)
$cr = New-Object Q+RECT; [void][Q]::GetClientRect($h, [ref]$cr)
"window=$($wr.L),$($wr.T)-$($wr.R),$($wr.B) size=$($wr.R-$wr.L)x$($wr.B-$wr.T)"
"client=$($cr.R)x$($cr.B)"
$bmp = New-Object System.Drawing.Bitmap $cr.R, $cr.B
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [Q]::PrintWindow($h, $hdc, 1)
$g.ReleaseHdc($hdc); $g.Dispose()
$bmp.Save('C:\NetGuard\ui-client.png', [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"printwindow=$ok"
[void][Q]::SetCursorPos(700, 400); Start-Sleep -Milliseconds 300; [void][Q]::SetCursorPos(720, 420)
Start-Sleep 2
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$b2 = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g2 = [System.Drawing.Graphics]::FromImage($b2)
$g2.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $b2.Size)
$b2.Save('C:\NetGuard\ui-screen.png', [System.Drawing.Imaging.ImageFormat]::Png)
$g2.Dispose(); $b2.Dispose()
'done'
