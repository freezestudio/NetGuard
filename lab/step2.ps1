$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$log="$RepoRoot\lab\step2.log"
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 单步 status+apply ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8
$cred=New-Object System.Management.Automation.PSCredential('freeze',(ConvertTo-SecureString '1' -AsPlainText -Force))
$s=New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\build\NetGuard.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Invoke-Command -Session $s -ScriptBlock { Remove-Item 'C:\ProgramData\NetGuard\ng.log','C:\ProgramData\NetGuard\filters.txt' -ErrorAction SilentlyContinue }
Invoke-Command -Session $s -ScriptBlock { & cmd.exe /c "C:\NetGuard\NetGuard.exe status" | Out-Null; "status exit=$LASTEXITCODE" } | ForEach-Object { L "  $_" }
Invoke-Command -Session $s -ScriptBlock { & cmd.exe /c "C:\NetGuard\NetGuard.exe apply" | Out-Null; "apply exit=$LASTEXITCODE" } | ForEach-Object { L "  $_" }
$r=Invoke-Command -Session $s -ScriptBlock { Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 30 }
$r | ForEach-Object { L "  $_" }
Remove-PSSession $s
L 完成
