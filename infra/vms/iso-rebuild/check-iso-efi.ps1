$VmsRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
$iso="$VmsRoot\iso-rebuild\Win11-EnterpriseEval-24H2-en-us.iso"
$m=Mount-DiskImage -ImagePath $iso -PassThru
Start-Sleep 2
$d=(Get-Volume -DiskImage $m).DriveLetter
Write-Host ('drive=' + $d)
Get-ChildItem ($d + ':\efi') -Recurse -ErrorAction SilentlyContinue | Select-Object FullName,Length | Format-Table -AutoSize
Get-ChildItem ($d + ':\boot') -Recurse -ErrorAction SilentlyContinue | Select-Object FullName,Length | Format-Table -AutoSize
Dismount-DiskImage -ImagePath $iso | Out-Null
