$ErrorActionPreference = 'Continue'
. 'C:\src\NetGuard\lab\ng-lab-common.ps1'
$log = 'C:\src\NetGuard\lab\svc-test.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 服务化验证（Win7 开机自启 + 自动下发）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "C:\VMs\$vmName\disk.vhdx"
$exe    = 'C:\src\NetGuard\build\NetGuard.exe'

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null

Copy-Item $exe "$ng\NetGuard.exe" -Force
Remove-Item "$ng\TESTONCE.flag" -Force -ErrorAction SilentlyContinue
Remove-Item "$pd\filters.txt", "$pd\ng.log", "$pd\selftest.txt" -Force -ErrorAction SilentlyContinue

# 离线准备：随机部署密钥 + 已签名策略（服务在开机阶段读取注册表密钥）
if (-not (Test-Path "$pd\policy.ini")) {
    Copy-Item 'C:\src\NetGuard\lab\policy-win10.ini' "$pd\policy.ini" -Force
}
$svcKey = New-NgPolicyKey
Sign-NgPolicyFile -PolicyPath "$pd\policy.ini" -Key $svcKey
L "已更新 exe，策略已用离线密钥签名，清理旧日志/过滤器记录"

# 启用服务（Start=2 自动），并清掉 RunOnce
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\S7V' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\S7V\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $csKey = "HKLM:\S7V\ControlSet00$cur\Services\NetGuard"
    New-Item -Path $csKey -Force | Out-Null
    Set-ItemProperty $csKey -Name Type         -Value 0x10 -Type DWord
    Set-ItemProperty $csKey -Name Start        -Value 2 -Type DWord
    Set-ItemProperty $csKey -Name ErrorControl -Value 1 -Type DWord
    Set-ItemProperty $csKey -Name ImagePath    -Value 'C:\NetGuard\NetGuard.exe' -Type ExpandString
    Set-ItemProperty $csKey -Name ObjectName   -Value 'LocalSystem' -Type String
    Set-ItemProperty $csKey -Name DisplayName  -Value 'NetGuard Egress Control' -Type String
    L "服务已设为自动启动（Start=2）"
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\S7V' 2>&1 | Out-Null
}
$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\W7V' $sw 2>&1 | Out-Null
if ($?) {
    Set-NgOfflineKey -LoadedHive 'W7V' -Key $svcKey
    Remove-ItemProperty 'HKLM:\W7V\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgTest -ErrorAction SilentlyContinue
    [gc]::Collect(); Start-Sleep -Milliseconds 700
    & reg unload 'HKLM\W7V' 2>&1 | Out-Null
    L "已清理 RunOnce"
}
[GC]::Collect()
Dismount-VHD -Path $vhd

# 开机，只等（不登录），验证服务在无用户登录的情况下下发策略
Start-VM -Name $vmName
L "开机，等待 180 秒（服务在启动阶段即应下发策略）"
Start-Sleep -Seconds 180
if ((Get-VM -Name $vmName).State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"

L "--- filters.txt（服务下发的过滤器 ID）---"
$fp = "$root\ProgramData\NetGuard\filters.txt"
if (Test-Path $fp) {
    $lines = Get-Content $fp
    L "  条数: $($lines.Count)"
    $lines | ForEach-Object { L "    $_" }
} else { L "  缺失" }

L "--- ng.log（服务日志）---"
$lp = "$root\ProgramData\NetGuard\ng.log"
if (Test-Path $lp) { Get-Content $lp -Encoding UTF8 | Select-Object -Last 20 | ForEach-Object { L "  $_" } } else { L "  缺失" }

[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
