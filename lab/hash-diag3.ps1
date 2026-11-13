$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\hash-diag3.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== sha256 诊断 v3 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe' -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
L "新 exe 已投放"

$r = Invoke-Command -Session $s -ScriptBlock {
    Remove-Item 'C:\ProgramData\NetGuard\ng.log' -ErrorAction SilentlyContinue
    $out = & cmd.exe /c 'C:\NetGuard\NetGuard.exe hash C:\Windows\win.ini' 2>&1
    "hash 输出: $out"
    "--- ng.log ---"
    Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 10
}
$r | ForEach-Object { L "  $_" }
Remove-PSSession $s
L "完成"
