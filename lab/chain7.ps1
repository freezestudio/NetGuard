$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\chain7.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 磁盘链诊断 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$dir = "C:\VMs\$vmName"
$vm = Get-VM -Name $vmName
L "自动检查点: $($vm.AutomaticCheckpointsEnabled)"
L "快照策略: $($vm.CheckpointType)"

L "--- 文件夹 ---"
Get-ChildItem $dir -Force | Sort-Object Name | ForEach-Object { L ("  {0,-60} {1,12:N0} {2}" -f $_.Name, $_.Length, $_.LastWriteTime) }

L "--- 快照对象 ---"
$snaps = Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue
if ($snaps) { $snaps | ForEach-Object { L "  $($_.Name)  $($_.CreationTime)  ParentSnapshot=$($_.ParentSnapshotName)" } } else { L "  (无)" }

L "--- VHD 链 ---"
foreach ($f in Get-ChildItem $dir -Filter '*.vhdx') {
    try {
        $h = Get-VHD -Path $f.FullName -ErrorAction Stop
        L ("  {0}`n      Type={1} Size={2:N1}GB FileSize={3:N0}MB Parent={4}" -f `
            $f.Name, $h.VhdType, ($h.Size/1GB), ($f.Length/1MB), $h.ParentPath)
        L "      ParentExists=$(if ($h.ParentPath) { Test-Path $h.ParentPath } else { 'n/a' })"
    } catch { L "  $($f.Name): 读取失败 $($_.Exception.Message)" }
}

L "--- VM 关联的磁盘 ---"
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  $($_.Path)" }

L "--- 尝试合并孤立 avhdx ---"
$avhdx = Get-ChildItem $dir -Filter '*.avhdx' | Select-Object -First 1
if ($avhdx) {
    $base = Join-Path $dir 'disk.vhdx'
    try {
        $h = Get-VHD -Path $avhdx.FullName -ErrorAction Stop
        L "  avhdx 的父盘: $($h.ParentPath)"
        if ($h.ParentPath -and (Test-Path $h.ParentPath) -and ((Resolve-Path $h.ParentPath).Path -eq (Resolve-Path $base).Path)) {
            # 先把 VM 的磁盘指回父盘，再合并
            $drv = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
            Set-VMHardDiskDrive -VMName $vmName -ControllerType $drv.ControllerType -ControllerNumber $drv.ControllerNumber `
                                -ControllerLocation $drv.ControllerLocation -Path $base -ErrorAction Stop
            L "  已把 VM 磁盘指回 disk.vhdx"
            Merge-VHD -Path $avhdx.FullName -DestinationPath $base -Force -ErrorAction Stop
            L "  合并完成"
            Remove-Item $avhdx.FullName -Force -ErrorAction SilentlyContinue
            L "  已删除 avhdx"
        } else { L "  父盘不匹配或不存在，跳过合并" }
    } catch { L "  合并失败: $($_.Exception.Message)" }
}

L "--- 再次尝试启动 ---"
try {
    Start-VM -Name $vmName -ErrorAction Stop
    Start-Sleep 10
    L "  状态: $((Get-VM -Name $vmName).State)"
} catch { L "  启动失败: $($_.Exception.Message)" }
L "完成"
