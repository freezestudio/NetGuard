# 自动处理 RDP 首次连接的安全警告：勾选“剪贴板”，点“连接/是”。
# 注意：这个安全警告的控件在 UIAutomation 里是 Pane，不是 CheckBox/Button，
# 所以用 BoundingRectangle + 鼠标点击，而不是 Toggle/Invoke。
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class NgMouse {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
}
'@

function Click-Rect($rect) {
    $x = [int]($rect.X + $rect.Width / 2)
    $y = [int]($rect.Y + $rect.Height / 2)
    [NgMouse]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 150
    [NgMouse]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [NgMouse]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    Write-Host ('clicked at ' + $x + ',' + $y)
}

$root = [System.Windows.Automation.AutomationElement]::RootElement
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                     [System.Windows.Automation.Condition]::TrueCondition)

$clip = $null
$connect = $null
foreach ($e in $all) {
    try {
        $n = $e.Current.Name
        if (-not $n) { continue }
        if ($n -like '*剪贴板*') { $clip = $e }
        if ($n -like '连接*' -or $n -like '是*' -or $n -like 'Connect*' -or $n -like 'Yes*') { $connect = $e }
    } catch { }
}
if ($clip) {
    # 若支持 TogglePattern 且已勾选，则不重复点击
    $done = $false
    try {
        $tp = $clip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($tp.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) { $done = $true }
        else { $tp.Toggle(); $done = $true; Write-Host 'toggled clipboard via TogglePattern' }
    } catch { }
    if (-not $done) { Click-Rect $clip.Current.BoundingRectangle }
}
if ($connect) {
    Click-Rect $connect.Current.BoundingRectangle
    'connect clicked'
} else {
    'no connect button found'
}
