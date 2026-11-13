$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-progress.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 安装进度 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$disk = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk\.vhdx' } | Select-Object -First 1).Path

function Cap($tag) {
    try {
        $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
            TargetSystem = $cs; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
        if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
            $bmp = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $rect = New-Object System.Drawing.Rectangle(0, 0, 800, 600)
            $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
            $bmp.UnlockBits($d)
            $bmp.Save("C:\src\NetGuard\lab\w7inst-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            L "  截图 $tag ok"
        } else { L "  截图 $tag 失败 rv=$($res.ReturnValue)" }
    } catch { L "  截图异常: $($_.Exception.Message)" }
}

for ($i = 1; $i -le 4; $i++) {
    Start-Sleep -Seconds 45
    $st = Get-VM -Name $vmName
    $sz = if (Test-Path $disk) { [int]((Get-Item $disk).Length / 1MB) } else { 0 }
    L "T+$($i*45)s state=$($st.State) cpu=$($st.CPUUsage)% disk=${sz}MB"
    if ($i -eq 2) { Cap 'a' }
    if ($i -eq 4) { Cap 'b' }
}
L "完成"
