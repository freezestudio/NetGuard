$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\test2.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 服务形态测试 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$exe    = "$RepoRoot\build\NetGuard.exe"

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6; L "已关机" }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"
L "Windows 分区: $root"

# ── 1. 投放程序 + 策略 + 测试标记
$ng = "$root\NetGuard"
New-Item -ItemType Directory -Path $ng -Force | Out-Null
Copy-Item $exe "$ng\NetGuard.exe" -Force
Set-Content "$ng\TESTONCE.flag" 'go' -Encoding ascii

$policy = @'
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=医保前置
Cidr=10.10.10.10/32
Ports=8000-8005
Proto=TCP
Enable=1

[proc.1]
Name=医保客户端（占位）
Path=C:\Windows\System32\notepad.exe
Sha256=
Endpoint=医保前置
Enable=1
'@
[IO.File]::WriteAllText("$ng\policy.ini", ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
L "已投放 NetGuard.exe / policy.ini / TESTONCE.flag"

# ── 2. 离线注册服务（SYSTEM hive）
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\NGSYS' $sysHive 2>&1 | Out-Null
if (-not $?) { L "SYSTEM hive 加载失败"; Dismount-VHD $target; exit 1 }
$cur = (Get-ItemProperty 'HKLM:\NGSYS\Select' -ErrorAction SilentlyContinue).Current
if (-not $cur) { $cur = 1 }
$csKey = "HKLM:\NGSYS\ControlSet00$cur\Services\NetGuard"
New-Item -Path $csKey -Force | Out-Null
Set-ItemProperty $csKey -Name Type        -Value 0x10 -Type DWord
Set-ItemProperty $csKey -Name Start       -Value 2 -Type DWord
Set-ItemProperty $csKey -Name ErrorControl -Value 1 -Type DWord
Set-ItemProperty $csKey -Name ImagePath   -Value 'C:\NetGuard\NetGuard.exe' -Type ExpandString
Set-ItemProperty $csKey -Name ObjectName  -Value 'LocalSystem' -Type String
Set-ItemProperty $csKey -Name DisplayName -Value 'NetGuard Egress Control' -Type String
L "已在 ControlSet00$cur 注册服务 NetGuard (auto/LocalSystem)"
[gc]::Collect(); Start-Sleep -Milliseconds 900
& reg unload 'HKLM\NGSYS' 2>&1 | Out-Null
L "SYSTEM hive 已卸载"

[GC]::Collect()
Dismount-VHD -Path $target
L "磁盘已卸载"

Start-VM -Name $vmName
L "VM 已启动；服务会在开机时执行「应用→自检→回滚→自检」"
