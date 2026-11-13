$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$vmName = 'Win7-Pro-x64'
$vhd    = "$VmsRoot\$vmName\disk.vhdx"
$hostOut = "$RepoRoot\lab\final\win7"
$log = "$RepoRoot\lab\final-win7.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
New-Item -ItemType Directory -Path $hostOut -Force | Out-Null
"=== NetGuard Win7 full clean install $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }
L "VM stopped"

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "Windows volume: $root"
if (-not (Test-Path "$root\Windows")) { L "ERROR: Windows volume not found"; Dismount-VHD -Path $vhd; exit 1 }

# ---------- 清理旧安装/旧测试残留 ----------
L "--- cleanup old install ---"
foreach ($p in @("$root\NetGuard", "$root\ProgramData\NetGuard")) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue; L "removed $p" }
}
Get-ChildItem "$root\Windows\System32\Tasks" -Filter 'Ng*' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    L "removed task $($_.Name)"
}

$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\NG7SYS' $sysHive 2>&1 | Out-Null
$cur = 1
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\NG7SYS\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $svcKey = "HKLM:\NG7SYS\ControlSet00$cur\Services\NetGuard"
    if (Test-Path $svcKey) { Remove-Item $svcKey -Recurse -Force; L "removed service registry key" }
    $compName = (Get-ItemProperty "HKLM:\NG7SYS\ControlSet00$cur\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NG7SYS' 2>&1 | Out-Null
} else { L "SYSTEM hive load failed" }

$swHive = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\NG7SOFT' $swHive 2>&1 | Out-Null
if ($?) {
    if (Test-Path 'HKLM:\NG7SOFT\NetGuard') { Remove-Item 'HKLM:\NG7SOFT\NetGuard' -Recurse -Force; L "removed HKLM\SOFTWARE\NetGuard" }

    $runOnce = 'HKLM:\NG7SOFT\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item -Path $runOnce -Force | Out-Null
    Get-Item $runOnce | Select-Object -ExpandProperty Property | Where-Object { $_ -like 'Ng*' } | ForEach-Object {
        Remove-ItemProperty -Path $runOnce -Name $_ -Force -ErrorAction SilentlyContinue
        L "removed RunOnce $_"
    }
    $run = 'HKLM:\NG7SOFT\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $run) {
        Get-Item $run | Select-Object -ExpandProperty Property | Where-Object { $_ -like 'Ng*' } | ForEach-Object {
            Remove-ItemProperty -Path $run -Name $_ -Force -ErrorAction SilentlyContinue
            L "removed Run $_"
        }
    }

    # 保证免 UAC、自动登录、免 Ctrl+Alt+Del
    $sysPol = 'HKLM:\NG7SOFT\Microsoft\Windows\CurrentVersion\Policies\System'
    New-Item -Path $sysPol -Force | Out-Null
    Set-ItemProperty $sysPol -Name EnableLUA -Value 0 -Type DWord
    Set-ItemProperty $sysPol -Name DisableCAD -Value 1 -Type DWord
    $wl = 'HKLM:\NG7SOFT\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $wl -Name AutoAdminLogon  -Value '1' -Type String
    Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
    Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
    if ($compName) { Set-ItemProperty $wl -Name DefaultDomainName -Value $compName -Type String }
    Set-ItemProperty $wl -Name ForceAutoLogon -Value '1' -Type String

    Set-ItemProperty $runOnce -Name NgFresh -Type String -Value 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\NetGuard\guest-win7-fresh.ps1"'
    L "RunOnce NgFresh configured"
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NG7SOFT' 2>&1 | Out-Null
} else { L "SOFTWARE hive load failed" }

# ---------- 投放全新构建与测试脚本 ----------
$ng = "$root\NetGuard"
New-Item -ItemType Directory -Path $ng -Force | Out-Null
foreach ($f in @('NetGuard.exe','NetGuardUI.exe')) {
    Copy-Item "$RepoRoot\build\$f" "$ng\$f" -Force
    L "deployed $f $((Get-Item "$ng\$f").Length) bytes"
}
foreach ($f in @('install-netguard.ps1','uninstall-netguard.ps1')) {
    Copy-Item "$RepoRoot\$f" "$ng\$f" -Force
    L "deployed $f"
}
foreach ($f in @('guest-win7-fresh.ps1','guest-ui-test.ps1')) {
    Copy-Item "$RepoRoot\lab\$f" "$ng\$f" -Force
    L "deployed $f"
}
# 确保没有旧口令/策略
if (Test-Path "$root\ProgramData\NetGuard") { L "WARNING: ProgramData still exists" }

[gc]::Collect()
Dismount-VHD -Path $vhd
L "VHD dismounted"

# ---------- 开机执行 ----------
Start-VM -Name $vmName
L "VM started, waiting for automated install/test/shutdown (max 12 min)"
$off = $false
for ($i = 0; $i -lt 72; $i++) {
    Start-Sleep 10
    $st = (Get-VM -Name $vmName).State
    if ($i % 6 -eq 0) { L "  T+$($i*10)s state=$st" }
    if ($st -eq 'Off') { $off = $true; L "guest shut down"; break }
}
if (-not $off) { Stop-VM -Name $vmName -TurnOff -Force; L "forced power off"; Start-Sleep 8 }

# ---------- 回收结果 ----------
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "collecting from $root"

$srcFinal = "$root\NetGuard\final"
if (Test-Path $srcFinal) {
    New-Item -ItemType Directory -Path $hostOut -Force | Out-Null
    Get-ChildItem $srcFinal -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $hostOut $_.Name) -Force
        L "collected $($_.Name)"
    }
} else { L "WARNING: guest final dir missing" }

$srcCap = "$root\NetGuard\captures"
if (Test-Path $srcCap) {
    $capOut = Join-Path $hostOut 'captures'
    New-Item -ItemType Directory -Path $capOut -Force | Out-Null
    Get-ChildItem $srcCap -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $capOut $_.Name) -Force
        L "collected capture $($_.Name)"
    }
} else { L "WARNING: guest captures dir missing" }

$srcPd = "$root\ProgramData\NetGuard"
if (Test-Path $srcPd) {
    $pdOut = Join-Path $hostOut 'programdata'
    New-Item -ItemType Directory -Path $pdOut -Force | Out-Null
    Get-ChildItem $srcPd -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $pdOut $_.Name) -Force
        L "collected $($_.Name)"
    }
} else { L "WARNING: ProgramData missing" }

L "--- guest.log tail ---"
$gl = Join-Path $hostOut 'guest.log'
if (Test-Path $gl) { Get-Content $gl -Encoding UTF8 | Select-Object -Last 80 | ForEach-Object { L "  $_" } }
else { L "  guest.log missing" }
L "--- ui-test.log tail ---"
$ul = Join-Path $hostOut 'captures\ui-test.log'
if (Test-Path $ul) { Get-Content $ul -Encoding UTF8 | Select-Object -Last 40 | ForEach-Object { L "  $_" } }
else { L "  ui-test.log missing" }

[GC]::Collect()
Dismount-VHD -Path $vhd
L "DONE"
