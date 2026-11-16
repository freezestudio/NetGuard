$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$log = "$RepoRoot\lab\check-win7-exports2.log"
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== check win7 exports2 ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$v = Get-VM -Name 'Win7-Pro-x64' -ErrorAction SilentlyContinue
if ($v -and $v.State -ne 'Off') { Stop-VM -Name 'Win7-Pro-x64' -TurnOff -Force; Start-Sleep 3 }
$vhd = "$VmsRoot\Win7-Pro-x64\disk.vhdx"
$m = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $m | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$dumpbin = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Tools\MSVC' -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -like '*Hostx64*x64*' } | Select-Object -First 1 -ExpandProperty FullName
$nt = & $dumpbin /exports "$root\Windows\System32\ntoskrnl.exe" 2>&1
$fw = & $dumpbin /exports "$root\Windows\System32\drivers\fwpkclnt.sys" 2>&1
$cg = & $dumpbin /exports "$root\Windows\System32\drivers\cng.sys" 2>&1
L '--- ntoskrnl suspicious ---'
foreach ($n in @('_snwprintf','_wcsnicmp','wcschr','ZwSetSecurityObject','SeCaptureSecurityDescriptor','IoIsWdmVersionAvailable','IoCreateDevice','ObOpenObjectByPointer','RtlAbsoluteToSelfRelativeSD','RtlAddAccessAllowedAce','RtlLengthSid','RtlSetDaclSecurityDescriptor','RtlCreateSecurityDescriptor','RtlGetDaclSecurityDescriptor','SeExports','ZwSetValueKey','ZwQueryValueKey')) {
    $hit = $nt | Select-String -SimpleMatch $n
    L (('{0,-32} {1}' -f $n, $(if ($hit) { 'YES' } else { 'NO' })))
}
L '--- fwpkclnt unregister ---'
$fw | Select-String -Pattern 'FwpsCalloutUnregister' | ForEach-Object { L ('  ' + $_) }
L '--- cng bcrypt ---'
$cg | Select-String -Pattern 'BCryptOpenAlgorithmProvider','BCryptCreateHash','BCryptHashData','BCryptFinishHash','BCryptGetProperty','BCryptDestroyHash','BCryptCloseAlgorithmProvider' | ForEach-Object { L ('  ' + $_) }
[gc]::Collect(); Start-Sleep -Milliseconds 500
Dismount-VHD -Path $vhd
L 'done'
