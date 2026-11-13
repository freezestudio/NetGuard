$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\shot7.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 启动画面 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 5 }
Start-VM -Name $vmName
L "已启动"

Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"

function Cap($tag) {
    try {
        $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
            TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
        if ($res.ReturnValue -ne 0) { L "  T+${tag}s 缩略图 rv=$($res.ReturnValue)"; return }
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rect = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d)
        $bmp.Save("C:\src\NetGuard\lab\w7-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        L "  T+${tag}s 截图 ok"
    } catch { L "  T+${tag}s 异常: $($_.Exception.Message)" }
}

foreach ($t in @(20, 45, 80)) {
    Start-Sleep -Seconds ($t - $(if ($t -eq 20) { 0 } else { $prev }))
    $prev = $t
    Cap $t
    $st = Get-VM -Name $vmName
    L "  T+${t}s state=$($st.State) cpu=$($st.CPUUsage)%"
}
L "完成"
