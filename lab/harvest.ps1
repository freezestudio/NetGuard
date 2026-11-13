$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\harvest.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== harvest $(Get-Date -Format o) ===" | Set-Content $log -Encoding utf8

# 先杀掉卡在 SendKeys 上的旧宿主脚本，避免它稍后也去挂载 VHD
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'tut-host\.ps1' } | ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force; L "killed stuck worker $($_.ProcessId)" } catch { L "kill failed $($_.ProcessId)" }
    }

$vmName = 'Win7-Pro-x64'
$vhd = "$VmsRoot\$vmName\disk.vhdx"
$outDir = "$RepoRoot\lab\tutorial"

# 等客人机自己关机（最多 12 分钟）
$off = $false
for ($i = 0; $i -lt 72; $i++) {
    $st = (Get-VM -Name $vmName).State
    if ($st -eq 'Off') { $off = $true; break }
    Start-Sleep 10
}
L "off=$off state=$((Get-VM -Name $vmName).State)"
if (-not $off) { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8; L "forced off" }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "volume=$root"

New-Item -ItemType Directory -Path (Join-Path $outDir 'shots') -Force | Out-Null
Get-ChildItem "$root\NetGuard\tut\shots" -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $outDir "shots\$($_.Name)") -Force
    L "shot $($_.Name) $($_.Length)"
}
Get-ChildItem "$root\NetGuard\tut" -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.Extension -in @('.log', '.txt') } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $outDir $_.Name) -Force
    L "log $($_.Name)"
}
New-Item -ItemType Directory -Path (Join-Path $outDir 'programdata') -Force | Out-Null
Get-ChildItem "$root\ProgramData\NetGuard" -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $outDir "programdata\$($_.Name)") -Force
    L "data $($_.Name)"
}
[gc]::Collect()
Dismount-VHD -Path $vhd
L "DONE"
