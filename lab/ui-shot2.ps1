$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\ui-shot2.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 交互桌面截图 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WS2 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@
$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))

$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vmName*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $vc) {
    Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
    Start-Sleep 12
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vmName*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
if ($vc) {
    [WS2]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [WS2]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
    [WS2]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 900
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('^r')
    Start-Sleep -Seconds 2
    [System.Windows.Forms.SendKeys]::SendWait('C:\NetGuard\NetGuardUI.exe --screenshot C:\NetGuard\ui2.bmp')
    Start-Sleep -Milliseconds 600
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    L "已在交互桌面启动 UI（--screenshot 模式）"
} else { L "!! 无 VMConnect 窗口" }

Start-Sleep -Seconds 10

$s = New-PSSession -VMName $vmName -Credential $cred
$r = Invoke-Command -Session $s -ScriptBlock {
    if (Test-Path 'C:\NetGuard\ui2.bmp') { "bmp=" + (Get-Item 'C:\NetGuard\ui2.bmp').Length } else { "bmp 缺失" }
    Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 4
}
$r | ForEach-Object { L "  $_" }
try {
    Copy-Item -FromSession $s -Path 'C:\NetGuard\ui2.bmp' -Destination 'C:\src\NetGuard\lab\ui2.bmp' -Force
    L "已取回: $((Get-Item 'C:\src\NetGuard\lab\ui2.bmp').Length) 字节"
} catch { L "取回失败: $($_.Exception.Message)" }
Remove-PSSession $s
L "完成"
