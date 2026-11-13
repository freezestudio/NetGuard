$log='C:\VMs\iso-rebuild\win11-secureboot-off.log'
function L($m){$line='{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'),$m; Add-Content $log $line -Encoding UTF8; Write-Host $line}
'=== secure boot off test ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$name='Win11-Test'
Set-VMFirmware -VMName $name -EnableSecureBoot Off
L 'SecureBoot Off'
if ((Get-VM -Name $name).State -eq 'Running') { Stop-VM -Name $name -TurnOff -Force; Start-Sleep 4 }
Start-VM -Name $name
L 'VM started with SecureBoot Off'
Set-Content 'C:\VMs\iso-rebuild\win11-secureboot-off-done.txt' (Get-Date -Format o) -Encoding UTF8
