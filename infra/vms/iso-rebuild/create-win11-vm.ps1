$ErrorActionPreference = 'Stop'
$log = 'C:\VMs\iso-rebuild\create-win11-vm.log'
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== create Win11 VM ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$name = 'Win11-Test'
$dir = 'C:\VMs\Win11-Test'
$vhd = Join-Path $dir 'disk.vhdx'
$win11 = 'C:\VMs\iso-rebuild\Win11-EnterpriseEval-24H2-en-us.iso'
$answer = 'C:\VMs\iso-rebuild\autounattend-win11.iso'

$old = Get-VM -Name $name -ErrorAction SilentlyContinue
if ($old) {
    L 'removing existing Win11-Test VM'
    Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
    Remove-VM -Name $name -Force
}
New-Item -ItemType Directory -Path $dir -Force | Out-Null
if (Test-Path $vhd) { Remove-Item $vhd -Force }

L 'creating Gen2 VM (4 vCPU / 6GB / 80GB / vTPM / SecureBoot On)'
New-VM -Name $name -Generation 2 -MemoryStartupBytes 6GB -NewVHDPath $vhd -NewVHDSizeBytes 80GB `
       -SwitchName 'Default Switch' | Out-Null
Set-VM -Name $name -ProcessorCount 4 -StaticMemory -AutomaticCheckpointsEnabled $false
Set-VMKeyProtector -VMName $name -NewLocalKeyProtector
Set-VM -Name $name -TpmEnabled $true
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

Add-VMDvdDrive -VMName $name -Path $win11 | Out-Null
Add-VMDvdDrive -VMName $name -Path $answer | Out-Null
$dvd = Get-VMDvdDrive -VMName $name | Where-Object { $_.Path -eq $win11 }
Set-VMFirmware -VMName $name -FirstBootDevice $dvd

Get-VM -Name $name | Select-Object Name,State,Generation,ProcessorCount,MemoryStartupBytes | Format-List | Out-String | ForEach-Object { L $_ }
Get-VMDvdDrive -VMName $name | Select-Object ControllerNumber,ControllerLocation,Path | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
Get-VMFirmware -VMName $name | Select-Object SecureBoot,SecureBootTemplate | Format-List | Out-String | ForEach-Object { L $_ }

Start-VM -Name $name
L 'VM started; Windows Setup should use autounattend.xml from the second DVD'
Set-Content 'C:\VMs\iso-rebuild\create-win11-vm-done.txt' (Get-Date -Format o) -Encoding UTF8
