$log='C:\VMs\iso-rebuild\win11-hdd-first.log'
function L($m){$line='{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'),$m; Add-Content $log $line -Encoding UTF8; Write-Host $line}
'=== set hdd first ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$name='Win11-Test'
$hdd=Get-VMHardDiskDrive -VMName $name | Select-Object -First 1
L ('hdd=' + $hdd.Path + ' state=' + (Get-VM -Name $name).State)
try {
    Set-VMFirmware -VMName $name -FirstBootDevice $hdd -ErrorAction Stop
    L 'Set-VMFirmware OK'
} catch {
    L ('Set-VMFirmware ERR: ' + $_.Exception.Message)
}
Get-VMFirmware -VMName $name | Select-Object BootOrder,SecureBoot | Format-List | Out-String | ForEach-Object { L $_ }
Set-Content 'C:\VMs\iso-rebuild\win11-hdd-first-done.txt' (Get-Date -Format o) -Encoding UTF8
