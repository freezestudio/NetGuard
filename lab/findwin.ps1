Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; public class FW { [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr FindWindow(string c, string n); [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h); }
'@
$o='C:\NetGuard\findwin.txt'
"session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)" | Out-File $o -Encoding utf8
$h=[FW]::FindWindow('NgInputWnd',$null)
"find=0x{0:X} iswin={1} err={2}" -f $h.ToInt64(),[FW]::IsWindow($h),[Runtime.InteropServices.Marshal]::GetLastWin32Error() | Out-File $o -Append -Encoding utf8
$h2=[FW]::FindWindow('NgInputWnd','设置管理员口令')
"find2=0x{0:X}" -f $h2.ToInt64() | Out-File $o -Append -Encoding utf8
'DONE' | Out-File $o -Append -Encoding utf8
