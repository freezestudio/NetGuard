$VmsRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$iso = "$VmsRoot\iso-rebuild\Win11-EnterpriseEval-24H2-en-us.iso"
$m = Mount-DiskImage -ImagePath $iso -PassThru
Start-Sleep 2
$vol = Get-Volume -DiskImage $m
$drive = $vol.DriveLetter
Write-Host ('drive=' + $drive)
Get-ChildItem ($drive + ':\') | Select-Object Name,Length | Format-Table -AutoSize
Get-ChildItem ($drive + ':\sources') -Filter 'install.*' | Select-Object Name,Length | Format-Table -AutoSize
Get-WindowsImage -ImagePath ($drive + ':\sources\install.wim') | Select-Object ImageIndex,ImageName,ImageSize | Format-Table -AutoSize
Dismount-DiskImage -ImagePath $iso | Out-Null
