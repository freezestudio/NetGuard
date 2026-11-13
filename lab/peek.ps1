$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\peek.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 窥屏 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$st = (Get-VM -Name $vmName).State
L "状态: $st"
if ($st -ne 'Running') { Start-VM -Name $vmName; Start-Sleep 20; L "已启动" }

Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"

function Cap($tag) {
    for ($try = 0; $try -lt 3; $try++) {
        try {
            $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
                TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
            if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
                $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $rect = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
                $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
                $bmp.UnlockBits($d)
                $bmp.Save("$RepoRoot\lab\peek-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                L "  $tag 截图 ok"
                return
            }
            L "  $tag rv=$($res.ReturnValue)，重试"
        } catch { L "  $tag 异常 $($_.Exception.Message)" }
        Start-Sleep 5
    }
}

Cap 'now'
Start-Sleep -Seconds 30
Cap 'later'
$s = Get-VM -Name $vmName
L "状态: $($s.State) CPU=$($s.CPUUsage)%"

# 顺便看看客户机有没有产生新文件（说明进了系统）
$p = "$RepoRoot\lab\peek.txt"
"state=$($s.State)" | Out-File $p -Encoding utf8
L "完成"
