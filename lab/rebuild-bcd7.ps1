$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\rebuild-bcd7.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 重建 Win7 BIOS BCD ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$parts = Get-Partition -DiskNumber $disk.Number
$srL  = (($parts | Where-Object { $_.Size -lt 200MB } | Select-Object -First 1) | Get-Volume).DriveLetter
$winL = (($parts | Sort-Object Size -Descending | Select-Object -First 1) | Get-Volume).DriveLetter
L "系统保留=$($srL):  Windows=$($winL):"

$bcdDir = "$($srL):\Boot"
$bcd = "$bcdDir\BCD"
L "--- 现有 BCD 备份 ---"
if (Test-Path $bcd) { Copy-Item $bcd "$bcd.bak" -Force; L "  已备份到 BCD.bak" } else { L "  没有 BCD（将新建）" }

L "--- 检查引导文件 ---"
foreach ($f in "$($srL):\bootmgr", "$bcdDir\boot.sdi", "$bcdDir\bootfix.bin", "$($winL):\Windows\System32\winload.exe") {
    L "  $(Test-Path $f)  $f"
}

L "--- 重建 BCD 存储 ---"
Remove-Item $bcd -Force -ErrorAction SilentlyContinue
Push-Location $bcdDir
$o = & bcdedit /createstore 2>&1
L "  createstore exit=$LASTEXITCODE  $(($o | Out-String).Trim())"
Pop-Location
L "  BCD 存在: $(Test-Path $bcd)"

function Bc([string[]]$a) {
    $r = & bcdedit @a 2>&1
    L ("  " + ($a[3..($a.Count - 1)] -join ' ') + " -> exit=$LASTEXITCODE " + (($r | Out-String).Trim()))
}

Bc @('/store', $bcd, '/create', '{bootmgr}', '/d', 'Windows Boot Manager')
Bc @('/store', $bcd, '/set', '{bootmgr}', 'device', ('partition=' + $srL + ':'))
Bc @('/store', $bcd, '/set', '{bootmgr}', 'timeout', '5')
Bc @('/store', $bcd, '/set', '{bootmgr}', 'locale', 'zh-CN')
Bc @('/store', $bcd, '/create', '{default}', '/d', 'Windows 7', '/application', 'osloader')
Bc @('/store', $bcd, '/set', '{default}', 'device', ('partition=' + $winL + ':'))
Bc @('/store', $bcd, '/set', '{default}', 'osdevice', ('partition=' + $winL + ':'))
Bc @('/store', $bcd, '/set', '{default}', 'path', '\Windows\system32\winload.exe')
Bc @('/store', $bcd, '/set', '{default}', 'systemroot', '\Windows')
Bc @('/store', $bcd, '/set', '{default}', 'locale', 'zh-CN')
Bc @('/store', $bcd, '/set', '{bootmgr}', 'displayorder', '{default}')

L "--- 未盘符映射时的修正说明 ---"

[GC]::Collect()
Dismount-VHD -Path $target
L "已卸载（本次仅验证 createstore 可行性）"
L "完成"
