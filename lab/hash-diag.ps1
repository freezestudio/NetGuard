$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\hash-diag.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== hash 命令诊断 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

$r = Invoke-Command -Session $s -ScriptBlock {
    $out = @()
    foreach ($t in @('C:\Windows\win.ini','C:\Windows\System32\notepad.exe','C:\NetGuard\NetGuardUI.exe','C:\NetGuard\biz.exe')) {
        $o = & cmd.exe /c "C:\NetGuard\NetGuard.exe hash `"$t`" 2>&1 & echo EXIT=%ERRORLEVEL%"
        $out += "FILE=$t"
        $out += ($o | ForEach-Object { "  " + $_ })
    }
    $out
}
$r | ForEach-Object { L "  $_" }

# 顺便用 PowerShell 侧算同一文件的哈希做对照
$ref = Invoke-Command -Session $s -ScriptBlock {
    (Get-FileHash 'C:\Windows\win.ini' -Algorithm SHA256).Hash
}
L "  PowerShell 对照哈希(win.ini): $ref"
Remove-PSSession $s
L "完成"
