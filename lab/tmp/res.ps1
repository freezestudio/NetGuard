Add-Type @'
using System; using System.Runtime.InteropServices;
public class R {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public uint dmFields;
    public int dmPositionX, dmPositionY;
    public uint dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public ushort dmLogPixels;
    public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
}
'@
$modes = @()
for ($i=0; $i -lt 300; $i++) {
  $dm = New-Object R+DEVMODE
  $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]('R+DEVMODE'))
  if (-not [R]::EnumDisplaySettings($null, $i, [ref]$dm)) { break }
  $modes += [pscustomobject]@{ W=[int]$dm.dmPelsWidth; H=[int]$dm.dmPelsHeight; B=[int]$dm.dmBitsPerPel; F=[int]$dm.dmDisplayFrequency }
}
"modes found=$($modes.Count)"
$modes | Sort-Object W,H | Select-Object -Unique W,H | ForEach-Object { "  $($_.W)x$($_.H)" }
$target = $modes | Where-Object { $_.W -eq 1600 -and $_.H -eq 900 } | Select-Object -First 1
if (-not $target) { $target = $modes | Where-Object { $_.W -eq 1920 -and $_.H -eq 1080 } | Select-Object -First 1 }
if ($target) {
  $dm = New-Object R+DEVMODE
  $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]('R+DEVMODE'))
  [void][R]::EnumDisplaySettings($null, -1, [ref]$dm)
  $dm.dmPelsWidth = $target.W; $dm.dmPelsHeight = $target.H; $dm.dmBitsPerPel = $target.B
  $dm.dmFields = 0x80000 -bor 0x100000 -bor 0x40000  # WIDTH|HEIGHT|BITSPERPEL
  $rc = [R]::ChangeDisplaySettings([ref]$dm, 0)
  "ChangeDisplaySettings $($target.W)x$($target.H) -> $rc (0=success)"
} else { 'no suitable mode' }
