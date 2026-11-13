$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\ipc-test3.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== IPC/哈希 复测 v2 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

# 1) 先看 ng.log 里 apply 失败的真实原因
L "--- ng.log 尾部 ---"
Invoke-Command -Session $s -ScriptBlock {
    if (Test-Path 'C:\ProgramData\NetGuard\ng.log') { Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 | Select-Object -Last 25 }
    else { "(无 ng.log)" }
} | ForEach-Object { L "  $_" }

# 2) 在客户机内计算 biz.exe 的哈希（客户机能运行我们的 exe）
$h1 = Invoke-Command -Session $s -ScriptBlock {
    (Get-Item 'C:\NetGuard\NetGuard.exe').Length
    & cmd.exe /c "C:\NetGuard\NetGuard.exe hash C:\NetGuard\NetGuard.exe" 2>&1
}
L "客户机内 NetGuard.exe 大小/哈希: $($h1 -join ' | ')"

$hashLine = ($h1 | Where-Object { $_ -match '^[0-9A-Fa-f]{64}$' } | Select-Object -First 1)
L "解析到的哈希: $(if ($hashLine) { $hashLine } else { '(未取到)' })"

if ($hashLine) {
    # 3) 用真实哈希重建策略（业务程序 = NetGuard.exe 自身，便于替换测试）
    $policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=biz-target
Cidr=10.10.10.10/32
Ports=8000-8005
Proto=TCP
Enable=1

[proc.1]
Name=biz-program
Path=C:\NetGuard\biz.exe
Sha256=$hashLine
Endpoint=biz-target
Enable=1
"@
    $tmpPol = 'C:\src\NetGuard\lab\policy-ipc2.ini'
    [IO.File]::WriteAllText($tmpPol, ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
    Copy-Item 'C:srcNetGuarduildNetGuard.exe' -ToSession $s -Destination 'C:NetGuardNetGuard.exe' -Force
    Copy-Item $tmpPol -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
    L "策略已更新（含真实哈希）"

    function Ctl($cmd) {
        $out = Invoke-Command -Session $s -ScriptBlock { param($c) & cmd.exe /c "C:\NetGuard\NetGuard.exe ctl $c" 2>&1 } -ArgumentList $cmd
        L "  ctl $cmd -> $(($out -join ' / '))"
    }
    Ctl 'apply'
    Ctl 'status'

    # 4) 替换 biz.exe → 看门狗应检测到并撤销
    Invoke-Command -Session $s -ScriptBlock {
        Copy-Item 'C:\NetGuard\NetGuardUI.exe' 'C:\NetGuard\biz.exe' -Force
    }
    L "已把 biz.exe 换成 NetGuardUI.exe（哈希不同），等待看门狗 ..."
    Start-Sleep -Seconds 70
    Ctl 'status'

    L "--- audit.log 尾部 ---"
    Invoke-Command -Session $s -ScriptBlock {
        if (Test-Path 'C:\ProgramData\NetGuard\audit.log') { Get-Content 'C:\ProgramData\NetGuard\audit.log' -Encoding UTF8 | Select-Object -Last 12 }
    } | ForEach-Object { L "  $_" }

    L "--- ng.log 尾部 ---"
    Invoke-Command -Session $s -ScriptBlock {
        Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 | Select-Object -Last 15
    } | ForEach-Object { L "  $_" }
}
Remove-PSSession $s
L "完成"
