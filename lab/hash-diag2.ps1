$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$cred=New-Object System.Management.Automation.PSCredential('freeze',(ConvertTo-SecureString '1' -AsPlainText -Force))
$s=New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\build\NetGuard.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Invoke-Command -Session $s -ScriptBlock { Remove-Item 'C:\ProgramData\NetGuard\ng.log' -ErrorAction SilentlyContinue; & cmd.exe /c "C:\NetGuard\NetGuard.exe hash C:\Windows\win.ini"; Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 8 }
Remove-PSSession $s
