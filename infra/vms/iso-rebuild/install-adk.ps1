$log = 'C:\VMs\iso-rebuild\install-adk.log'
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== install ADK Deployment Tools ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$setup = 'C:\VMs\iso-rebuild\adksetup.exe'
L 'starting adksetup'
$p = Start-Process -FilePath $setup -ArgumentList @('/quiet','/norestart','/ceip','off','/features','OptionId.DeploymentTools') -Wait -PassThru
L ('adksetup exit=' + $p.ExitCode)
$oscdimg = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit' -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
L ('oscdimg=' + $(if ($oscdimg) { $oscdimg } else { 'missing' }))
if ($oscdimg) { & $oscdimg 2>&1 | Select-Object -First 3 | ForEach-Object { L ('  ' + $_) } }
L 'done'
Set-Content 'C:\VMs\iso-rebuild\install-adk-done.txt' (Get-Date -Format o) -Encoding UTF8
