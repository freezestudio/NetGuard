$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\restore7b.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 修 ACL + 回滚 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$dir = "$VmsRoot\$vmName"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

L "--- 当前 ACL ---"
& icacls $dir 2>&1 | ForEach-Object { L "  $_" }

L "--- takeown ---"
& takeown /f $dir /r /d Y 2>&1 | Select-Object -Last 6 | ForEach-Object { L "  $_" }

L "--- 授予 Administrators 与 Virtual Machines 完全控制 ---"
& icacls $dir /grant "*S-1-5-32-544:(OI)(CI)F" /T /C 2>&1 | Select-Object -Last 6 | ForEach-Object { L "  $_" }
& icacls $dir /grant "*S-1-5-83-0:(OI)(CI)F" /T /C 2>&1 | Select-Object -Last 3 | ForEach-Object { L "  $_" }
$me = "$env:COMPUTERNAME\$env:USERNAME"
& icacls $dir /grant "${me}:(OI)(CI)F" /T /C 2>&1 | Select-Object -Last 3 | ForEach-Object { L "  $_" }

L "--- 重试回滚 ---"
try {
    Restore-VMSnapshot -VMName $vmName -Name 'patched' -Confirm:$false -ErrorAction Stop
    L "回滚成功"
} catch {
    L "回滚失败: $($_.Exception.Message)"
}

Start-Sleep -Seconds 3
$snaps = Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue
L "快照: $(($snaps | ForEach-Object { $_.Name }) -join ', ')"
L "VM 状态: $((Get-VM -Name $vmName).State)"
L "完成"
