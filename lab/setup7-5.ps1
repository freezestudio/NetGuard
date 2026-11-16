$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\setup7-5.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 Setup 步骤5 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W4 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@
$vmName = 'Win7-Pro-x64'
$cs  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService

function Focus() {
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($vc) {
        [W4]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
        [W4]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
        [W4]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 700
    } else { L "  !! 无 VMConnect 窗口" }
}
function Key($k, $desc) { Focus; L "  发送 [$desc] $k"; [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 1200 }
function Cap($tag) {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $r = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d); $bmp.Save("$RepoRoot\lab\r7-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        L "  截图 r7-$tag.png"
    }
}

L "[1] 接受许可条款（Alt+A）"
Key '%a' '接受许可'
Start-Sleep -Seconds 3; Cap 'license'

L "[2] 下一步（Enter）"
Key '{ENTER}' '下一步'
Start-Sleep -Seconds 15; Cap 'type'

L "[3] 自定义安装（Alt+C）"
Key '%c' '自定义安装'
Start-Sleep -Seconds 15; Cap 'partition'

L "[4] 分区界面 → Enter"
Key '{ENTER}' '分区下一步'
Start-Sleep -Seconds 40; Cap 'installing'

L "[5] 等 100 秒看是否开始复制文件"
Start-Sleep -Seconds 100; Cap 'installing2'
$sz = if (Test-Path "$VmsRoot\Win7-Pro-x64\disk.vhdx") { [int]((Get-Item "$VmsRoot\Win7-Pro-x64\disk.vhdx").Length/1MB) } else { 0 }
L "磁盘大小: ${sz}MB"
L "完成"
