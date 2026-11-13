$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\grab-nglog.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 读取客户机 ng.log ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$sec = ConvertTo-SecureString '1' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('freeze', $sec)
$s = New-PSSession -VMName $vmName -Credential $cred

$r = Invoke-Command -Session $s -ScriptBlock {
    $p = 'C:\ProgramData\NetGuard\ng.log'
    if (Test-Path $p) { Get-Content $p -Encoding UTF8 | Select-Object -Last 60 } else { '（无 ng.log）' }
}
$r | ForEach-Object { L "  $_" }

L "--- 目录 ---"
$d = Invoke-Command -Session $s -ScriptBlock {
    if (Test-Path 'C:\ProgramData\NetGuard') { Get-ChildItem 'C:\ProgramData\NetGuard' | Select-Object Name, Length } else { 'no dir' }
}
$d | ForEach-Object { L "  $_" }

Remove-PSSession $s
L "完成"
