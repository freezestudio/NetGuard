$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\state7.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 当前状态 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) { L "VM 不存在"; exit 1 }
L "State=$($vm.State)  AutoCheckpoints=$($vm.AutomaticCheckpointsEnabled)  Mem=$([int]($vm.MemoryStartup/1MB))MB  CPU=$($vm.ProcessorCount)"

L "--- 磁盘 ---"
foreach ($d in Get-VMHardDiskDrive -VMName $vmName) {
    $p = if ($d.Path) { $d.Path } else { '(空)' }
    $name = if ($d.Path) { Split-Path -Leaf $d.Path } else { '(无)' }
    L "  HDD $($d.ControllerType)$($d.ControllerNumber):$($d.ControllerLocation)  $name"
}
L "--- 光驱 ---"
foreach ($d in Get-VMDvdDrive -VMName $vmName) {
    $name = if ($d.Path) { Split-Path -Leaf $d.Path } else { '(无)' }
    L "  DVD $($d.ControllerNumber):$($d.ControllerLocation)  $name"
}
L "--- 网络 ---"
foreach ($n in Get-VMNetworkAdapter -VMName $vmName) { L "  $($n.Name) switch=$($n.SwitchName) legacy=$($n.IsLegacy)" }

if ($vm.State -ne 'Running') {
    L "--- 启动 ---"
    try { Start-VM -Name $vmName -ErrorAction Stop; Start-Sleep 10; L "  状态: $((Get-VM -Name $vmName).State)" }
    catch { L "  启动失败: $($_.Exception.Message)" }
}

$st = (Get-VM -Name $vmName).State
if ($st -eq 'Running') {
    Start-Sleep -Seconds 100
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
            $bmp.UnlockBits($d); $bmp.Save("$RepoRoot\lab\state7.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
            L "截图 state7.png"; break
        } else { L "缩略图 rv=$($res.ReturnValue)"; Start-Sleep 6 }
    }
}
L "完成"
