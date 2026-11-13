$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\diag-start7.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 启动诊断 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) { L "VM 不存在"; exit 1 }

L "State          : $($vm.State)"
L "StatusDesc     : $($vm.StatusDescriptions -join ' | ')"
L "OperationalSt  : $($vm.OperationalStatus -join ',')"
L "HealthState    : $($vm.HealthState)"
L "MemoryStartup  : $([int]($vm.MemoryStartup/1MB))MB  Assigned=$([int]($vm.MemoryAssigned/1MB))MB"
L "ProcessorCount : $($vm.ProcessorCount)"

L "--- 设备 ---"
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  HDD $($_.ControllerType)$($_.ControllerNumber):$($_.ControllerLocation) $($_.Path)  exists=$(Test-Path $_.Path)" }
Get-VMDvdDrive -VMName $vmName | ForEach-Object { L "  DVD $($_.ControllerNumber):$($_.ControllerLocation) $($_.Path)" }
Get-VMSnapshot -VMName $vmName | ForEach-Object { L "  快照: $($_.Name)" }

L "--- VHD 是否被宿主挂载 ---"
try {
    $di = Get-DiskImage -ImagePath "$VmsRoot\Win7-Pro-x64\disk.vhdx" -ErrorAction SilentlyContinue
    if ($di) {
        $di | Select-Object ImagePath, Attached, DevicePath | Format-List | Out-String | ForEach-Object { L $_ }
    } else { L "  未挂载" }
} catch { L "  查询失败: $($_.Exception.Message)" }

L "--- 宿主内存 ---"
$os = Get-CimInstance Win32_OperatingSystem
L ("  可用: {0:N1} GB / 总 {1:N1} GB" -f ($os.FreePhysicalMemory/1MB), ($os.TotalVisibleMemorySize/1MB))

L "--- 尝试启动 ---"
try {
    Start-VM -Name $vmName -ErrorAction Stop
    Start-Sleep 8
    L "  启动成功，状态: $((Get-VM -Name $vmName).State)"
} catch {
    L "  启动失败: $($_.Exception.Message)"
    L "  --- 再试一次（先等待）---"
    Start-Sleep 10
    try { Start-VM -Name $vmName -ErrorAction Stop; Start-Sleep 8; L "  第二次成功: $((Get-VM -Name $vmName).State)" }
    catch { L "  第二次仍失败: $($_.Exception.Message)" }
}
L "完成"
