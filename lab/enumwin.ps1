Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; public class EW { public delegate bool EnumProc(IntPtr h, IntPtr l); [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l); [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n); [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid); }
'@
$out='C:\NetGuard\windows.txt'
"session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)" | Out-File $out -Encoding utf8
$cb={ param($h,$l); $sb=New-Object System.Text.StringBuilder 512; [void][EW]::GetWindowText($h,$sb,512); $cn=New-Object System.Text.StringBuilder 256; [void][EW]::GetClassName($h,$cn,256); $pid2=0; [void][EW]::GetWindowThreadProcessId($h,[ref]$pid2); if([EW]::IsWindowVisible($h)){ "hwnd=$h pid=$pid2 class=$($cn.ToString()) title=$($sb.ToString())" | Out-File $out -Append -Encoding utf8 }; return $true }
[void][EW]::EnumWindows($cb,[IntPtr]::Zero)
'DONE' | Out-File $out -Append -Encoding utf8
