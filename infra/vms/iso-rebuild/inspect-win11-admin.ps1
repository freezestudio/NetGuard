$VmsRoot = Split-Path $PSScriptRoot -Parent
$log = "$VmsRoot\iso-rebuild\inspect-win11-admin.log"
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== inspect win11 iso ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$iso = "$VmsRoot\iso-rebuild\Win11-EnterpriseEval-24H2-en-us.iso"
try { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null } catch { }
Start-Sleep 2
$m = Mount-DiskImage -ImagePath $iso -PassThru
Start-Sleep 2
$drive = (Get-Volume -DiskImage $m).DriveLetter
L ('drive=' + $drive)
$imgs = Get-WindowsImage -ImagePath ($drive + ':\sources\install.wim') -ErrorAction Stop
$imgs | Select-Object ImageIndex,ImageName,ImageSize | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
Dismount-DiskImage -ImagePath $iso | Out-Null
L 'done'
Set-Content "$VmsRoot\iso-rebuild\inspect-win11-admin-done.txt" (Get-Date -Format o) -Encoding UTF8
