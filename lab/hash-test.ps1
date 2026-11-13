$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
. "$RepoRoot\lab\ng-lab-common.ps1"
$log = "$RepoRoot\lab\hash-test.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 哈希锁定 + 防替换 最终测试 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

# 1) 停服务（释放 exe 占用）
Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 3
    & sc.exe delete NetGuard 2>&1 | Out-Null
    Start-Sleep 2
    Get-Process NetGuard -ErrorAction SilentlyContinue | Stop-Process -Force
    "service stopped+deleted"
} | ForEach-Object { L "  $_" }

# 2) 投放新 exe（现在不会被占用）
Copy-Item "$RepoRoot\build\NetGuard.exe"   -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item "$RepoRoot\build\NetGuardUI.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
Copy-Item "$RepoRoot\build\NetGuardUI.exe" -ToSession $s -Destination 'C:\NetGuard\biz.exe' -Force
$sz = Invoke-Command -Session $s -ScriptBlock { (Get-Item 'C:\NetGuard\NetGuard.exe').Length }
L "投放完成（NetGuard.exe = $sz 字节，新版应为 46 万以上）"

# 3) 先在客户机里确认 hash 命令可用（看埋点）
$hashOut = Invoke-Command -Session $s -ScriptBlock {
    Remove-Item 'C:\ProgramData\NetGuard\ng.log' -ErrorAction SilentlyContinue
    $o1 = & cmd.exe /c 'C:\NetGuard\NetGuard.exe hash C:\Windows\win.ini' 2>&1
    $o2 = & cmd.exe /c 'C:\NetGuard\NetGuard.exe hash C:\NetGuard\biz.exe' 2>&1
    "win.ini  -> $o1"
    "biz.exe  -> $o2"
    "--- ng.log ---"
    Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 8
}
$hashOut | ForEach-Object { L "  $_" }

# 取 biz.exe 的哈希（64 位十六进制）
$bizHash = ($hashOut | Where-Object { $_ -match 'biz\.exe\s+->\s+([0-9A-Fa-f]{64})' } |
            ForEach-Object { [regex]::Match($_, '([0-9A-Fa-f]{64})').Groups[1].Value } | Select-Object -First 1)
L "biz.exe 哈希: $(if ($bizHash) { $bizHash } else { '(未取到)' })"

if ($bizHash) {
    # 4) 写带哈希的策略并装服务
    $policy = "[general]`r`nDefaultDeny=1`r`nAllowDhcp=1`r`nAllowLoopback=1`r`nTempAllowUntil=0`r`n`r`n" +
              "[ep.1]`r`nName=biz-target`r`nCidr=10.10.10.10/32`r`nPorts=8000-8005`r`nProto=TCP`r`nEnable=1`r`n`r`n" +
              "[proc.1]`r`nName=biz-program`r`nPath=C:\NetGuard\biz.exe`r`nSha256=$bizHash`r`nEndpoint=biz-target`r`nEnable=1`r`n"
    $tmp = "$RepoRoot\lab\policy-hash.ini"
    [IO.File]::WriteAllText($tmp, $policy, (New-Object Text.UTF8Encoding($false)))
    Copy-Item $tmp -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
    L "策略已写入（哈希锁定 biz.exe）"
    Sign-NgGuestPolicy -Session $s | ForEach-Object { L "  $_" }

    $r = Invoke-Command -Session $s -ScriptBlock {
        & cmd.exe /c 'C:\NetGuard\NetGuard.exe install' 2>&1 | Out-Null
        & sc.exe start NetGuard 2>&1 | Out-Null
        Start-Sleep 6
        (& sc.exe query NetGuard 2>&1 | Select-String 'STATE') -join ' ; '
    }
    L "服务: $r"

    function Ctl($cmd) {
        $out = Invoke-Command -Session $s -ScriptBlock { param($c) & cmd.exe /c "C:\NetGuard\NetGuard.exe ctl $c" 2>&1 } -ArgumentList $cmd
        L "  ctl $cmd -> $(($out -join ' / '))"
    }
    Ctl 'apply'
    Ctl 'status'

    # 5) 替换 biz.exe（换成 NetGuardUI.exe 的字节）→ 看门狗应撤销该条目
    Invoke-Command -Session $s -ScriptBlock {
        Copy-Item 'C:\Windows\System32\notepad.exe' 'C:\NetGuard\biz.exe' -Force
        'biz.exe replaced with notepad.exe'
    } | ForEach-Object { L "  $_" }
    L "等待看门狗（45 秒）..."
    Start-Sleep -Seconds 45
    Ctl 'status'

    L "--- audit.log ---"
    Invoke-Command -Session $s -ScriptBlock {
        if (Test-Path 'C:\ProgramData\NetGuard\audit.log') { Get-Content 'C:\ProgramData\NetGuard\audit.log' -Encoding UTF8 | Select-Object -Last 12 }
    } | ForEach-Object { L "  $_" }

    L "--- policy.ini 中 biz-program 的 Enable ---"
    Invoke-Command -Session $s -ScriptBlock {
        Get-Content 'C:\ProgramData\NetGuard\policy.ini' -Encoding UTF8 | Select-String -Pattern 'Name=biz-program' -Context 0,5
    } | ForEach-Object { L "  $_" }

    L "--- ng.log 尾部 ---"
    Invoke-Command -Session $s -ScriptBlock {
        Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 | Select-Object -Last 12
    } | ForEach-Object { L "  $_" }
}
Remove-PSSession $s
L "完成"
