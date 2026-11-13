$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$log="$RepoRoot\lab\click-vmconnect.log"
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== click $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices; public class VC { [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,IntPtr l); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y); [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,int e); }
'@
$p=Get-Process vmconnect -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if(-not $p){ L 'no vmconnect'; exit }
[void][VC]::SetForegroundWindow($p.MainWindowHandle)
$root=[System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
$all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
for($i=0;$i -lt $all.Count;$i++){
  $e=$all.Item($i)
  if($e.Current.Name -match '^连接\(N\)'){
    $nh=$e.Current.NativeWindowHandle
    L "found $($e.Current.Name) hwnd=$nh rect=$($e.Current.BoundingRectangle)"
    if($nh -ne 0){
      $lp=[IntPtr]((16 -shl 16) -bor 56)
      [void][VC]::SendMessage([IntPtr]$nh,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
      [void][VC]::SendMessage([IntPtr]$nh,0x0201,[IntPtr]1,$lp)
      [void][VC]::SendMessage([IntPtr]$nh,0x0202,[IntPtr]0,$lp)
      L 'sent BM_CLICK + WM_LBUTTON'
    }
    $r=$e.Current.BoundingRectangle
    [void][VC]::SetCursorPos([int]($r.X+$r.Width/2),[int]($r.Y+$r.Height/2))
    [VC]::mouse_event(0x0002,0,0,0,0); [VC]::mouse_event(0x0004,0,0,0,0)
    L 'sent mouse_event'
  }
}
Start-Sleep 8
'DONE' | Out-File $log -Append -Encoding utf8
