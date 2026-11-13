$ErrorActionPreference = 'Stop'
$log = 'C:\VMs\iso-rebuild\build-win11-unattend.log'
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== build Win11 unattend ISO ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8

$name = 'Win11-Test'
$srcIso = 'C:\VMs\iso-rebuild\Win11-EnterpriseEval-24H2-en-us.iso'
$answer = 'C:\VMs\iso-rebuild\answer\autounattend.xml'
$root = 'C:\VMs\iso-rebuild\win11-root'
$outIso = 'C:\VMs\iso-rebuild\Win11-EnterpriseEval-24H2-unattend.iso'
$oscdimg = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'

if ((Get-VM -Name $name).State -ne 'Off') { Stop-VM -Name $name -TurnOff -Force; Start-Sleep 4 }
try { Dismount-DiskImage -ImagePath $srcIso -ErrorAction SilentlyContinue | Out-Null } catch { }

L 'mounting source ISO'
$m = Mount-DiskImage -ImagePath $srcIso -PassThru
Start-Sleep 2
$drive = (Get-Volume -DiskImage $m).DriveLetter
L ('source drive=' + $drive)

if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null
L 'copying ISO contents (5.4GB) ...'
$rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList @(($drive + ':\'), $root, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:2') -Wait -PassThru
L ('robocopy exit=' + $rc.ExitCode)
Dismount-DiskImage -ImagePath $srcIso | Out-Null
if ($rc.ExitCode -ge 8) { throw 'robocopy failed' }
Copy-Item $answer (Join-Path $root 'autounattend.xml') -Force
L 'autounattend.xml placed at ISO root'

$bootdata = '-bootdata:2#p0,e,b"' + (Join-Path $root 'boot\etfsboot.com') + '"#pEF,e,b"' + (Join-Path $root 'efi\microsoft\boot\efisys_noprompt.bin') + '"'
L 'running oscdimg ...'
if (Test-Path $outIso) { Remove-Item $outIso -Force }
$p = Start-Process -FilePath $oscdimg -ArgumentList @('-m','-o','-u2','-udfver102','-h',$bootdata,$root,$outIso) -Wait -PassThru
L ('oscdimg exit=' + $p.ExitCode)
if (-not (Test-Path $outIso)) { throw 'ISO create failed' }
Get-Item $outIso | Select-Object FullName,@{n='GB';e={[math]::Round($_.Length/1GB,2)}} | Format-List | Out-String | ForEach-Object { L $_ }

# replace VM DVD
$dvds = @(Get-VMDvdDrive -VMName $name)
foreach ($d in $dvds) { Remove-VMDvdDrive -VMName $name -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation }
Add-VMDvdDrive -VMName $name -Path $outIso | Out-Null
$dvd = Get-VMDvdDrive -VMName $name | Select-Object -First 1
Set-VMFirmware -VMName $name -FirstBootDevice $dvd
Get-VMDvdDrive -VMName $name | Select-Object ControllerNumber,ControllerLocation,Path | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
L 'starting VM with unattend ISO (no key prompt expected)'
Start-VM -Name $name
Set-Content 'C:\VMs\iso-rebuild\build-win11-unattend-done.txt' (Get-Date -Format o) -Encoding UTF8
