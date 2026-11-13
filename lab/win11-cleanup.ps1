$RepoRoot = Split-Path $PSScriptRoot -Parent
$log = "$RepoRoot\lab\win11-cleanup.log"
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== Win11 cleanup ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
try { & 'C:\NetGuard\NetGuard.exe' ctl rollback 2>&1 | ForEach-Object { L ('  ' + $_) } } catch { }
& "$env:SystemRoot\System32\sc.exe" stop NetGuard 2>&1 | ForEach-Object { L ('  ' + $_) }
Start-Sleep 2
& "$env:SystemRoot\System32\sc.exe" delete NetGuard 2>&1 | ForEach-Object { L ('  ' + $_) }
Start-Sleep 2
Get-Process NetGuard -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
try { & 'C:\NetGuard\NetGuard.exe' purge 2>&1 | ForEach-Object { L ('  ' + $_) } } catch { }
Copy-Item "$RepoRoot\build\NetGuard.exe" 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item "$RepoRoot\build\NetGuardUI.exe" 'C:\NetGuard\NetGuardUI.exe' -Force
Remove-Item 'C:\NetGuard\auto-rollback.ps1' -Force -ErrorAction SilentlyContinue
L ('service exists=' + [bool](Get-Service NetGuard -ErrorAction SilentlyContinue))
L ('processes=' + @(Get-Process NetGuard -ErrorAction SilentlyContinue).Count)
L 'done'
Set-Content "$RepoRoot\lab\win11-cleanup-done.txt" (Get-Date -Format o) -Encoding UTF8
