$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$log = "$RepoRoot\lab\host-win11-capability-probe.log"
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== Win11 capability probe ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8

L '--- OS ---'
Get-CimInstance Win32_OperatingSystem |
  Select-Object Caption,Version,BuildNumber,OSArchitecture,InstallDate |
  Format-List | Out-String | ForEach-Object { L $_ }
Get-CimInstance Win32_ComputerSystem |
  Select-Object Manufacturer,Model,TotalPhysicalMemory,NumberOfLogicalProcessors |
  Format-List | Out-String | ForEach-Object { L $_ }
Get-PSDrive C | Select-Object Used,Free | Format-List | Out-String | ForEach-Object { L $_ }

L '--- features ---'
foreach ($f in @('Containers-DisposableClientVM','Microsoft-Hyper-V-All','VirtualMachinePlatform','Containers')) {
    try {
        $x = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
        L ('{0} = {1}' -f $f, $x.State)
    } catch { L ('{0} = ERR {1}' -f $f, $_.Exception.Message) }
}
L ('WindowsSandbox.exe exists = ' + (Test-Path 'C:\Windows\System32\WindowsSandbox.exe'))
try { L ('WindowsSandbox command = ' + ((Get-Command WindowsSandbox.exe -ErrorAction Stop).Source)) } catch { L 'WindowsSandbox command = missing' }

L '--- hyper-v ---'
Get-VMHost | Select-Object Name,LogicalProcessorCount,MemoryCapacity,EnableEnhancedSessionMode,VirtualMachinePath |
  Format-List | Out-String | ForEach-Object { L $_ }
Get-VMSwitch | Select-Object Name,SwitchType | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
try { Get-VMHostSupportedVersion | Select-Object Version,Default | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ } } catch { L ('VMHostSupportedVersion ERR ' + $_.Exception.Message) }

L '--- device guard / secure boot / testsigning ---'
try {
    Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
      Select-Object VirtualizationBasedSecurityStatus,SecurityServicesRunning,SecurityServicesConfigured |
      Format-List | Out-String | ForEach-Object { L $_ }
} catch { L ('DeviceGuard ERR ' + $_.Exception.Message) }
try { L ('SecureBoot = ' + (Confirm-SecureBootUEFI)) } catch { L ('SecureBoot = ERR ' + $_.Exception.Message) }
& bcdedit.exe /enum '{current}' 2>&1 | Select-String -Pattern 'testsigning','hypervisorlaunchtype','nointegritychecks' | ForEach-Object { L ('  ' + $_) }

L '--- cpu virtualization ---'
& systeminfo.exe 2>&1 | Select-String -Pattern 'Hyper-V Requirements','Virtualization Enabled In Firmware','Second Level Address Translation','Data Execution Prevention' | ForEach-Object { L ('  ' + $_) }

L '--- existing ISOs ---'
Get-ChildItem "$VmsRoot",'C:\Users\freez\Downloads','C:\Users\freez\Desktop' -Filter *.iso -Recurse -Depth 2 -ErrorAction SilentlyContinue |
  Select-Object FullName,@{n='GB';e={[math]::Round($_.Length/1GB,2)}} | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
L 'done'
Set-Content "$RepoRoot\lab\host-win11-capability-probe-done.txt" (Get-Date -Format o) -Encoding UTF8
