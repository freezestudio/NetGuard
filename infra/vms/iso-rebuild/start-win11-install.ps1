$VmsRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$log = "$VmsRoot\iso-rebuild\start-win11-install.log"
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== start Win11 install ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$name = 'Win11-Test'
$win11 = "$VmsRoot\iso-rebuild\Win11-EnterpriseEval-24H2-en-us.iso"
$answer = "$VmsRoot\iso-rebuild\autounattend-win11.iso"

$v = Get-VM -Name $name -ErrorAction Stop
L ('state=' + $v.State + ' tpm=' + $v.TpmEnabled)
try { Set-VMKeyProtector -VMName $name -NewLocalKeyProtector } catch { L ('keyprotector: ' + $_.Exception.Message) }
try { Enable-VMTPM -VMName $name -ErrorAction Stop; L 'vTPM enabled' } catch { L ('Enable-VMTPM: ' + $_.Exception.Message) }

$dvds = @(Get-VMDvdDrive -VMName $name -ErrorAction SilentlyContinue)
if (-not ($dvds | Where-Object { $_.Path -eq $win11 })) {
    Add-VMDvdDrive -VMName $name -Path $win11 | Out-Null
    L 'added Win11 DVD'
}
if (-not ($dvds | Where-Object { $_.Path -eq $answer })) {
    Add-VMDvdDrive -VMName $name -Path $answer | Out-Null
    L 'added answer DVD'
}
$dvd = Get-VMDvdDrive -VMName $name | Where-Object { $_.Path -eq $win11 } | Select-Object -First 1
Set-VMFirmware -VMName $name -FirstBootDevice $dvd
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

Get-VM -Name $name | Select-Object Name,State,Generation,ProcessorCount,MemoryStartupBytes,TpmEnabled | Format-List | Out-String | ForEach-Object { L $_ }
Get-VMDvdDrive -VMName $name | Select-Object ControllerNumber,ControllerLocation,Path | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
Get-VMFirmware -VMName $name | Select-Object SecureBoot,SecureBootTemplate | Format-List | Out-String | ForEach-Object { L $_ }

if ((Get-VM -Name $name).State -ne 'Running') { Start-VM -Name $name }
L 'Win11 install started'
Set-Content "$VmsRoot\iso-rebuild\start-win11-install-done.txt" (Get-Date -Format o) -Encoding UTF8
