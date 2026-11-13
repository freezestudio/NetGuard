$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\ui-selftest.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== NetGuardUI 结构自检 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item 'C:\ProgramData\NetGuard\ui-selftest.txt' -ErrorAction SilentlyContinue
}
Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
L "已投放最新 NetGuardUI.exe"

$r = Invoke-Command -Session $s -ScriptBlock {
    $p = Start-Process -FilePath 'C:\NetGuard\NetGuardUI.exe' -ArgumentList '--selftest' -PassThru -Wait
    "exit=$($p.ExitCode)"
    if (Test-Path 'C:\ProgramData\NetGuard\ui-selftest.txt') {
        Get-Content 'C:\ProgramData\NetGuard\ui-selftest.txt' -Encoding UTF8
    } else { "(没有生成 ui-selftest.txt)" }
}
$r | ForEach-Object { L "  $_" }
Remove-PSSession $s
L "完成"
