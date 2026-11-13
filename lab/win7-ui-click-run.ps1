$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-ui-click-run.log'
"=== Win7 UI click runner $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd = "C:\VMs\$vmName\disk.vhdx"
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"
New-Item -ItemType Directory -Path $ng -Force | Out-Null

Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' "$ng\NetGuardUI.exe" -Force
Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' "$ng\NGUI10.exe" -Force
Copy-Item 'C:\src\NetGuard\lab\win7-ui-click.ps1' "$ng\win7-ui-click.ps1" -Force
Remove-Item "$ng\ui-click-result.txt", "$ng\ui-click.png" -Force -ErrorAction SilentlyContinue
"deployed UI=$((Get-Item "$ng\NetGuardUI.exe").Length)" | Out-File $log -Append -Encoding utf8

$cmd = @'
@echo off
cd /d C:\NetGuard
schtasks /create /tn NgClick /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\NetGuard\win7-ui-click.ps1" /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f >nul 2>&1
schtasks /run /tn NgClick >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\ui-click.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\CK7' $sw 2>&1 | Out-Null
if ($?) {
    New-Item -Path 'HKLM:\CK7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\CK7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgClick -Value 'C:\NetGuard\ui-click.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\CK7' 2>&1 | Out-Null
    "RunOnce set" | Out-File $log -Append -Encoding utf8
}

[GC]::Collect()
Dismount-VHD -Path $vhd

Start-VM -Name $vmName
"boot, wait 120s" | Out-File $log -Append -Encoding utf8
Start-Sleep -Seconds 120
if ((Get-VM -Name $vmName).State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"

"--- ui-click-result.txt ---" | Out-File $log -Append -Encoding utf8
if (Test-Path "$root\NetGuard\ui-click-result.txt") {
    Get-Content "$root\NetGuard\ui-click-result.txt" -Encoding UTF8 | Out-File $log -Append -Encoding utf8
} else { "(missing)" | Out-File $log -Append -Encoding utf8 }

if (Test-Path "$root\NetGuard\ui-click.png") {
    Copy-Item "$root\NetGuard\ui-click.png" 'C:\src\NetGuard\lab\ui-click-win7.png' -Force
    "png copied" | Out-File $log -Append -Encoding utf8
} else { "png missing" | Out-File $log -Append -Encoding utf8 }

[GC]::Collect()
Dismount-VHD -Path $vhd
"=== done ===" | Out-File $log -Append -Encoding utf8
