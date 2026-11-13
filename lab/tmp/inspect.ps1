Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class W2 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  public static List<IntPtr> All() { var r=new List<IntPtr>(); EnumWindows((h,l)=>{ if(IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static string Text(IntPtr h){ var sb=new StringBuilder(512); GetWindowText(h,sb,512); return sb.ToString(); }
}
'@
[W2]::All() | ForEach-Object {
  $t = [W2]::Text($_)
  if ($t -like '*NetGuard*' -or $t -like '*cmd*') {
    $r = New-Object W2+RECT; [void][W2]::GetWindowRect($_, [ref]$r)
    "h=$($t) rect=$($r.L),$($r.T)-$($r.R),$($r.B) size=$($r.R-$r.L)x$($r.B-$r.T)"
  }
}
'--- display modes ---'
Add-Type @'
using System; using System.Runtime.InteropServices;
public class D {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
}
'@
$seen = @{}
for ($i=0; $i -lt 200; $i++) {
  $dm = New-Object D+DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
  if (-not [D]::EnumDisplaySettings($null, $i, [ref]$dm)) { break }
  $k = "$($dm.dmPelsWidth)x$($dm.dmPelsHeight)@$($dm.dmDisplayFrequency)"
  if (-not $seen.ContainsKey($k)) { $seen[$k]=1; "mode: $k bpp=$($dm.dmBitsPerPel)" }
}
Add-Type -AssemblyName System.Windows.Forms
'primary=' + ([System.Windows.Forms.Screen]::PrimaryScreen.Bounds)
'workarea=' + ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea)
