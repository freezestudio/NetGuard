$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\step-status.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 单步 status 测试 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8
$sec = ConvertTo-SecureString '1' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('freeze', $sec)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\build\NetGuard.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item "$RepoRoot\lab\policy-win10.ini" -ToSession $s -Destination 'C:\NetGuard\policy.ini' -Force
Invoke-Command -Session $s -ScriptBlock { Remove-Item 'C:\ProgramData\NetGuard\ng.log' -ErrorAction SilentlyContinue }
$r = Invoke-Command -Session $s -ScriptBlock {
    & cmd.exe /c "C:\NetGuard\NetGuard.exe status" | Out-Null
    "exit=$LASTEXITCODE"
    Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 25
}
$r | ForEach-Object { L "  $_" }
Remove-PSSession $s
L "完成"
