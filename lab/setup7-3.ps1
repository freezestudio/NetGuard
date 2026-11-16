$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\setup7-3.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 Setup 步骤3 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W2 {
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
    if (-not $vc) { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName; Start-Sleep 10; $vc = Get-Process vmconnect | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 }
    if ($vc) {
        [W2]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
        [W2]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
        [W2]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 600
    }
}
function Key($k) { Focus; L "  发送: $k"; [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 900 }
function Cap($tag) {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $r = New-Object System.Drawing.Rectangle(0, 0, 800, 600)
        $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d); $bmp.Save("$RepoRoot\lab\p7-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        L "  截图 p7-$tag.png"
    }
}

L "[1] 等安装程序就绪（30 秒）"
Start-Sleep -Seconds 30; Cap 'a'

L "[2] 现在安装 → Enter"
Key '{ENTER}'
Start-Sleep -Seconds 10; Cap 'b'

L "[3] 接受许可条款 → Alt+A，然后 Enter"
Key '%a'
Start-Sleep -Seconds 2
Key '{ENTER}'
Start-Sleep -Seconds 10; Cap 'c'

L "[4] 自定义安装 → Alt+C"
Key '%c'
Start-Sleep -Seconds 10; Cap 'd'

L "[5] 分区界面 → Enter（使用未分配空间）"
Key '{ENTER}'
Start-Sleep -Seconds 25; Cap 'e'

L "[6] 等安装推进（120 秒）"
Start-Sleep -Seconds 120; Cap 'f'
$st = Get-VM -Name $vmName
L "VM 状态: $($st.State) CPU=$($st.CPUUsage)%  磁盘=$(if (Test-Path "$VmsRoot\Win7-Pro-x64\disk.vhdx") { [int]((Get-Item "$VmsRoot\Win7-Pro-x64\disk.vhdx").Length/1MB) } else { 0 })MB"
L "完成"
