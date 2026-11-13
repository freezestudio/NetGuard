$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\ui-test3.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 在交互会话启动管理界面 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WV {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))

# 1) 杀掉会话 0 的 UI 实例
$s = New-PSSession -VMName $vmName -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
    "killed session0 instance"
} | ForEach-Object { L "  $_" }
Remove-PSSession $s
Start-Sleep 2

# 2) 通过 VMConnect + Win+R 在交互会话里启动
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vmName*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $vc) {
    Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
    Start-Sleep 10
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vmName*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
if ($vc) {
    [WV]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [WV]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
    [WV]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 800
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('^r')      # Win+R
    Start-Sleep -Seconds 2
    [System.Windows.Forms.SendKeys]::SendWait('C:\NetGuard\NetGuardUI.exe')
    Start-Sleep -Milliseconds 700
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    L "已通过 Win+R 启动 UI"
} else { L "!! 无 VMConnect 窗口" }

Start-Sleep -Seconds 8

# 3) 关闭 VMConnect（否则缩略图接口返回空）
Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vmName*" } | ForEach-Object {
    $_.CloseMainWindow() | Out-Null
}
Start-Sleep 5

# 4) 缩略图截图
$cs  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
$ok = $false
for ($i = 0; $i -lt 5; $i++) {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $r = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d); $bmp.Save("$RepoRoot\lab\ui2.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        L "截图 ui2.png"; $ok = $true; break
    } else { L "缩略图 rv=$($res.ReturnValue)"; Start-Sleep 5 }
}
# 5) 确认进程存在
$s = New-PSSession -VMName $vmName -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
    Get-Process NetGuardUI -ErrorAction SilentlyContinue |
        Select-Object Id, SessionId, MainWindowTitle | Format-Table -AutoSize | Out-String
} | ForEach-Object { L "  $_" }
Remove-PSSession $s
L "完成"
