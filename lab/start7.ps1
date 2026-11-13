$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\start7.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 启动 Win7 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName -ErrorAction Stop
L "当前状态: $($vm.State)"
if ($vm.State -eq 'Running') {
    L "已在运行，执行重启"
    Stop-VM -Name $vmName -TurnOff -Force
    Start-Sleep 8
} elseif ($vm.State -ne 'Off') {
    Stop-VM -Name $vmName -TurnOff -Force
    Start-Sleep 8
}
Start-VM -Name $vmName
L "已开机，等待 110 秒看是否自动登录进桌面"
Start-Sleep -Seconds 110

Add-Type -AssemblyName System.Drawing
$cs  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
for ($i = 0; $i -lt 3; $i++) {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $r = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d); $bmp.Save("$RepoRoot\lab\started7.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        L "截图 started7.png"; break
    } else { L "缩略图 rv=$($res.ReturnValue)"; Start-Sleep 6 }
}

# 顺便打开控制台窗口方便你操作
try { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName; L "已打开 VMConnect 窗口" } catch { L "vmconnect 失败: $($_.Exception.Message)" }
L "VM 状态: $((Get-VM -Name $vmName).State)"
L "完成"
