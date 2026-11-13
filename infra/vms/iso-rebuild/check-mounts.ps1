'--- mounted images ---'
Get-DiskImage -ImagePath 'C:\VMs\iso-rebuild\Win11-EnterpriseEval-24H2-en-us.iso' | Select-Object Attached,ImagePath | Format-List
Get-DiskImage -ImagePath 'C:\VMs\iso-rebuild\Win11-EnterpriseEval-24H2-unattend.iso' | Select-Object Attached,ImagePath | Format-List
'--- VM dvd drives ---'
Get-VM | ForEach-Object { Get-VMDvdDrive -VMName $_.Name | Select-Object VMName,ControllerNumber,ControllerLocation,Path } | Format-Table -AutoSize
'--- VM states ---'
Get-VM | Select-Object Name,State | Format-Table -AutoSize
