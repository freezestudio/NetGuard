Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class T {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  public static List<IntPtr> All() { var r=new List<IntPtr>(); EnumWindows((h,l)=>{ if(IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowText(h,sb,512); return sb.ToString(); }
}
'@
[void][T]::SetProcessDPIAware()
Add-Type -AssemblyName System.Drawing
$h = [IntPtr]::Zero
foreach ($x in [T]::All()) { if ([T]::Text($x) -like 'NetGuard - *') { $h = $x; break } }
if ($h -eq [IntPtr]::Zero) { 'no ui'; exit 1 }
function Shot($name) {
  $cr = New-Object T+RECT; [void][T]::GetClientRect($h, [ref]$cr)
  $wr = New-Object T+RECT; [void][T]::GetWindowRect($h, [ref]$wr)
  $bmp = New-Object System.Drawing.Bitmap $cr.R, $cr.B
  $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc(); $ok=[T]::PrintWindow($h,$hdc,1); $g.ReleaseHdc($hdc); $g.Dispose()
  $bmp.Save("C:\NetGuard\$name.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  "$name client=$($cr.R)x$($cr.B) win=$($wr.R-$wr.L)x$($wr.B-$wr.T) at $($wr.L),$($wr.T) pw=$ok"
}
Shot 'size-before'
foreach ($sz in @(@(1100,640),@(1250,700),@(1000,600))) {
  [void][T]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, $sz[0], $sz[1], 0x0040)
  Start-Sleep 2
  Shot ("size-" + $sz[0] + "x" + $sz[1])
}
