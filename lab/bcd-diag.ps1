$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\bcd-diag.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== bcdboot 诊断 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

$vhd = "$VmsRoot\$vmName\disk.vhdx"
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 2
$disk = $v | Get-Disk
foreach ($p in Get-Partition -DiskNumber $disk.Number) {
    $vol = $p | Get-Volume -ErrorAction SilentlyContinue
    L ("分区{0} active={1} 大小={2}MB FS={3} 盘符={4} 标签={5}" -f $p.PartitionNumber, $p.IsActive, [int]($p.Size/1MB), $vol.FileSystem, $vol.DriveLetter, $vol.FileSystemLabel)
}

$sysL = ($disk | Get-Partition | Where-Object { $_.Size -lt 200MB } | Select-Object -First 1 | Get-Volume).DriveLetter
$winL = ($disk | Get-Partition | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1 | Get-Volume).DriveLetter
L "系统保留=$($sysL):  Windows=$($winL):"

L "--- 系统保留分区内容 ---"
Get-ChildItem "$($sysL):\" -Force -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name)" }

L "--- 引导源文件 ---"
foreach ($f in 'boot\PCAT\bootmgr', 'boot\PCAT\boot.sdi', 'boot\EFI\bootmgfw.efi', 'System32\bcdboot.exe', 'System32\config\SYSTEM') {
    L "  $(Test-Path "$($winL):\Windows\$f")  Windows\$f"
}
L "--- Windows 目录大小 ---"
L ("  {0:N0} MB" -f ((Get-ChildItem "$($winL):\Windows" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB))

L "--- 重试 bcdboot /v ---"
$gb = "$($winL):\Windows\System32\bcdboot.exe"
$out = & $gb "$($winL):\Windows" /s "$($sysL):" /l zh-CN /v 2>&1
L "exit=$LASTEXITCODE"
$out | ForEach-Object { L "  $_" }
L "  BCD 存在: $(Test-Path "$($sysL):\Boot\BCD")  bootmgr: $(Test-Path "$($sysL):\bootmgr")"
L "--- 系统保留分区内容（重试后）---"
Get-ChildItem "$($sysL):\" -Force -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name)" }

[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
