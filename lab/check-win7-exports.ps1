$log = 'C:\src\NetGuard\lab\check-win7-exports.log'
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== check win7 exports ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$v = Get-VM -Name 'Win7-Pro-x64' -ErrorAction SilentlyContinue
if ($v -and $v.State -ne 'Off') { Stop-VM -Name 'Win7-Pro-x64' -TurnOff -Force; Start-Sleep 3 }
$vhd = 'C:\VMs\Win7-Pro-x64\disk.vhdx'
$m = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $m | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L ('volume=' + $root)
$dumpbin = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Tools\MSVC' -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -like '*Hostx64*x64*' } | Select-Object -First 1 -ExpandProperty FullName
L ('dumpbin=' + $dumpbin)
if ($dumpbin) {
    L '--- ntoskrnl exports ---'
    $nt = & $dumpbin /exports "$root\Windows\System32\ntoskrnl.exe" 2>&1
    $nt | Select-String -Pattern 'SeLocateProcessImageName','PsSetCreateProcessNotifyRoutine','PsLookupProcessByProcessId','PsGetProcessImageFileName' | ForEach-Object { L ('  ' + $_) }
    L '--- fwpkclnt exports ---'
    $fw = & $dumpbin /exports "$root\Windows\System32\drivers\fwpkclnt.sys" 2>&1
    $fw | Select-String -Pattern 'FwpsCalloutRegister','FwpmEngineOpen0','FwpmProviderAdd0','FwpmSubLayerAdd0','FwpmFilterAdd0','FwpmCalloutAdd0','FwpmTransaction' | ForEach-Object { L ('  ' + $_) }
}
[gc]::Collect(); Start-Sleep -Milliseconds 500
Dismount-VHD -Path $vhd
L 'done'
