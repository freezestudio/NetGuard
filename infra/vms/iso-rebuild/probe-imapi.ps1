$VmsRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$src="$VmsRoot\iso-rebuild\answer"
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3
$fsi.VolumeName = 'AUTOUNATTEND'
$fsi.Root.AddTree($src, $false)
$result = $fsi.CreateResultImage()
$stream = $result.ImageStream
'stream type: ' + $stream.GetType().FullName
$stream | Get-Member | Out-String
'--- result ---'
$result | Get-Member | Out-String
