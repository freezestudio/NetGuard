Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices; public class M5 { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y); [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,int e); }
'@
[void][M5]::SetProcessDPIAware()
function ClickRect($r) {
  [void][M5]::SetCursorPos([int]($r.X + $r.Width/2), [int]($r.Y + $r.Height/2))
  [M5]::mouse_event(0x0002,0,0,0,0); [M5]::mouse_event(0x0004,0,0,0,0)
  Start-Sleep -Milliseconds 800
}
for ($i=0; $i -lt 30; $i++) {
  $root=[System.Windows.Automation.AutomationElement]::RootElement
  $all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $acted=$false
  for ($j=0; $j -lt $all.Count; $j++) {
    $e=$all.Item($j); $n=$e.Current.Name; $ct=$e.Current.ControlType.ProgrammaticName
    if ($n -match '^我了解') {
      try { $tp=$e.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern); if ($tp.Current.ToggleState -ne 'On') { $tp.Toggle(); "toggled $n"; $acted=$true } } catch {}
    }
    if ($n -eq '确定' -and $ct -eq 'ControlType.Pane') { ClickRect $e.Current.BoundingRectangle; "clicked 确定"; $acted=$true }
    if ($n -match '^连接\(N\)' -and $ct -eq 'ControlType.Pane') { ClickRect $e.Current.BoundingRectangle; "clicked 连接(N)"; $acted=$true }
  }
  if (-not $acted) { Start-Sleep -Milliseconds 700 }
}
