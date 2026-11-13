$VmsRoot = Split-Path $PSScriptRoot -Parent
$log="$VmsRoot\iso-rebuild\win11-boot-isolate.log"
function L($m){$line='{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'),$m; Add-Content $log $line -Encoding UTF8; Write-Host $line}
'=== boot isolate ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$name='Win11-Test'
Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
Start-Sleep 4
Set-VMFirmware -VMName $name -EnableSecureBoot Off
$fw=Get-VMFirmware -VMName $name
L ('SecureBoot=' + $fw.SecureBoot)
# 只保留 Win11 ISO
$dvds=@(Get-VMDvdDrive -VMName $name)
foreach($d in $dvds){ if($d.Path -notlike '*Win11-EnterpriseEval*'){ L ('removing ' + $d.Path); Remove-VMDvdDrive -VMName $name -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation } }
$win=Get-VMDvdDrive -VMName $name | Select-Object -First 1
Set-VMFirmware -VMName $name -FirstBootDevice $win
Get-VMDvdDrive -VMName $name | Select-Object ControllerNumber,ControllerLocation,Path | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
Start-VM -Name $name
L 'started with Win11 ISO only, SecureBoot Off'
Set-Content "$VmsRoot\iso-rebuild\win11-boot-isolate-done.txt" (Get-Date -Format o) -Encoding UTF8
