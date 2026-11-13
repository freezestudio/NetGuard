$VmsRoot = Split-Path $PSScriptRoot -Parent
$log = "$VmsRoot\iso-rebuild\win11-checkpoint.log"
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== win11 checkpoint ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$name = 'Win11-Test'
$v = Get-VM -Name $name
if ($v.State -ne 'Off') {
    L ('stopping ' + $name + ' (graceful)')
    Stop-VM -Name $name -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep 2; if ((Get-VM -Name $name).State -eq 'Off') { break } }
    if ((Get-VM -Name $name).State -ne 'Off') { L 'forcing off'; Stop-VM -Name $name -TurnOff -Force }
}
L ('state=' + (Get-VM -Name $name).State)
$snap = 'clean-win11-testsigning'
$existing = Get-VMSnapshot -VMName $name -Name $snap -ErrorAction SilentlyContinue
if ($existing) { L 'checkpoint already exists'; Remove-VMSnapshot -VMName $name -Name $snap -Confirm:$false }
Checkpoint-VM -Name $name -SnapshotName $snap
L ('checkpoint created: ' + $snap)
Get-VMSnapshot -VMName $name | Select-Object Name,SnapshotType,CreationTime | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
Get-VM -Name $name | Select-Object Name,State,Generation,ProcessorCount,MemoryStartup,TpmEnabled | Format-List | Out-String | ForEach-Object { L $_ }
Set-Content "$VmsRoot\iso-rebuild\win11-checkpoint-done.txt" (Get-Date -Format o) -Encoding UTF8
