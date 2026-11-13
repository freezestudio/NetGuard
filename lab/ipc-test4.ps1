$ErrorActionPreference = 'Continue'
. 'C:\src\NetGuard\lab\ng-lab-common.ps1'
$log = 'C:\src\NetGuard\lab\ipc-test3.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 修复后复测：服务 + IPC + 哈希防替换 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

# 1) 停止/删除旧服务，投放新 exe
Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 2
    & sc.exe delete NetGuard 2>&1 | Out-Null
    Start-Sleep 1
    Remove-Item 'C:\ProgramData\NetGuard\audit.log','C:\ProgramData\NetGuard\ng.log','C:\ProgramData\NetGuard\filters.txt' -ErrorAction SilentlyContinue
}
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe'   -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe'   -ToSession $s -Destination 'C:\NetGuard\biz.exe' -Force
Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
L "新 exe 已投放（biz.exe = NetGuard.exe 副本）"

# 2) 客户机内算 biz.exe 的真实哈希
$hashOut = Invoke-Command -Session $s -ScriptBlock {
    & cmd.exe /c "C:\NetGuard\NetGuard.exe hash C:\NetGuard\biz.exe" 2>&1
}
$h = ($hashOut | Where-Object { $_ -match '^[0-9A-Fa-f]{64}$' } | Select-Object -First 1)
L "客户机算出 biz.exe 哈希: $(if ($h) { $h } else { '(失败: ' + ($hashOut -join ' ') + ')' })"

# 3) 写策略（带真实哈希 + 手工签名留空，apply 会告警但继续）
if ($h) {
    $policy = "[general]`r`nDefaultDeny=1`r`nAllowDhcp=1`r`nAllowLoopback=1`r`nTempAllowUntil=0`r`n`r`n" +
              "[ep.1]`r`nName=biz-target`r`nCidr=10.10.10.10/32`r`nPorts=8000-8005`r`nProto=TCP`r`nEnable=1`r`n`r`n" +
              "[proc.1]`r`nName=biz-program`r`nPath=C:\NetGuard\biz.exe`r`nSha256=$h`r`nEndpoint=biz-target`r`nEnable=1`r`n"
    $tmp = 'C:\src\NetGuard\lab\policy-ipc3.ini'
    [IO.File]::WriteAllText($tmp, $policy, (New-Object Text.UTF8Encoding($false)))
    Copy-Item $tmp -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
    L "策略已写入（哈希锁定）"
    Sign-NgGuestPolicy -Session $s | ForEach-Object { L "  $_" }
}

# 4) 安装并启动服务
$r = Invoke-Command -Session $s -ScriptBlock {
    & cmd.exe /c "C:\NetGuard\NetGuard.exe install" 2>&1
    & sc.exe start NetGuard 2>&1 | Out-Null
    Start-Sleep 6
    (& sc.exe query NetGuard 2>&1 | Select-String "STATE") -join ' ; '
}
L "服务: $r"

function Ctl($cmd) {
    $out = Invoke-Command -Session $s -ScriptBlock { param($c) & cmd.exe /c "C:\NetGuard\NetGuard.exe ctl $c" 2>&1 } -ArgumentList $cmd
    L "  ctl $cmd -> $(($out -join ' / '))"
}
Ctl 'apply'
Ctl 'status'

# 5) 替换 biz.exe → 看门狗应检测哈希变化并撤销该程序的白名单
Invoke-Command -Session $s -ScriptBlock { Copy-Item 'C:\NetGuard\NetGuardUI.exe' 'C:\NetGuard\biz.exe' -Force }
L "已替换 biz.exe（哈希不同），等待看门狗 45 秒 ..."
Start-Sleep -Seconds 45
Ctl 'status'

L "--- audit.log ---"
Invoke-Command -Session $s -ScriptBlock {
    if (Test-Path 'C:\ProgramData\NetGuard\audit.log') { Get-Content 'C:\ProgramData\NetGuard\audit.log' -Encoding UTF8 | Select-Object -Last 15 }
} | ForEach-Object { L "  $_" }

L "--- policy.ini 的 proc 段 ---"
Invoke-Command -Session $s -ScriptBlock {
    Get-Content 'C:\ProgramData\NetGuard\policy.ini' -Encoding UTF8 | Select-String -Pattern 'Sha256|Enable|Path=' | Select-Object -Last 6
} | ForEach-Object { L "  $_" }

Remove-PSSession $s
L "完成"
