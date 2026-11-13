$ErrorActionPreference = 'Continue'
. 'C:\src\NetGuard\lab\ng-lab-common.ps1'
$log = 'C:\src\NetGuard\lab\ipc-test.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 服务 + IPC + 哈希防替换 联合测试 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))

# 1) 计算宿主机 NetGuard.exe 的哈希（作为"合法业务程序"的基准）
$h1 = (& 'C:\src\NetGuard\build\NetGuard.exe' hash 'C:\src\NetGuard\build\NetGuard.exe')
L "合法程序哈希 H1 = $h1"

# 2) 生成测试策略（业务程序 = C:\NetGuard\biz.exe，哈希锁定 H1）
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
Sha256=$h1
Endpoint=biz-target
Enable=1
"@
$tmpPol = 'C:\src\NetGuard\lab\policy-ipc.ini'
[IO.File]::WriteAllText($tmpPol, ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))

$s = New-PSSession -VMName $vmName -Credential $cred
# 3) 部署
Invoke-Command -Session $s -ScriptBlock {
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
    & sc.exe stop NetGuard | Out-Null
    Start-Sleep 2
    & sc.exe delete NetGuard | Out-Null
    New-Item -ItemType Directory -Path 'C:\NetGuard','C:\ProgramData\NetGuard' -Force | Out-Null
    Remove-Item 'C:\ProgramData\NetGuard\audit.log','C:\ProgramData\NetGuard\ng.log','C:\ProgramData\NetGuard\filters.txt' -ErrorAction SilentlyContinue
}
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe'   -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe'   -ToSession $s -Destination 'C:\NetGuard\biz.exe' -Force
Copy-Item $tmpPol -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
Sign-NgGuestPolicy -Session $s | ForEach-Object { L "  $_" }
L "已部署 exe / biz.exe / policy.ini"

# 4) 安装并启动服务
$r = Invoke-Command -Session $s -ScriptBlock {
    & cmd.exe /c "C:\NetGuard\NetGuard.exe install" 2>&1
    & sc.exe start NetGuard 2>&1
    Start-Sleep 5
    & sc.exe query NetGuard 2>&1 | Select-String "STATE"
}
$r | ForEach-Object { L "  $_" }

# 5) 管道命令测试
function Ctl($cmd) {
    $out = Invoke-Command -Session $s -ScriptBlock { param($c) & cmd.exe /c "C:\NetGuard\NetGuard.exe ctl $c" 2>&1 } -ArgumentList $cmd
    L "  ctl $cmd ->"
    $out | ForEach-Object { L "    $_" }
}
Ctl 'status'
Ctl 'rollback'
Ctl 'status'
Ctl 'apply'
Ctl 'status'

# 6) 哈希防替换测试：把 biz.exe 换掉
Invoke-Command -Session $s -ScriptBlock {
    Copy-Item 'C:\NetGuard\NetGuardUI.exe' 'C:\NetGuard\biz.exe' -Force
    "biz.exe 已被替换为 NetGuardUI.exe"
} | ForEach-Object { L "  $_" }

L "等待看门狗（最多 70 秒）检测哈希变化 ..."
Start-Sleep -Seconds 70
Ctl 'status'

L "--- audit.log ---"
Invoke-Command -Session $s -ScriptBlock {
    if (Test-Path 'C:\ProgramData\NetGuard\audit.log') { Get-Content 'C:\ProgramData\NetGuard\audit.log' -Encoding UTF8 | Select-Object -Last 20 }
} | ForEach-Object { L "  $_" }

L "--- policy.ini 中 proc.1 的 Enable ---"
Invoke-Command -Session $s -ScriptBlock {
    Get-Content 'C:\ProgramData\NetGuard\policy.ini' -Encoding UTF8 | Select-String -Pattern 'Enable|Name=biz'
} | ForEach-Object { L "  $_" }

Remove-PSSession $s
L "完成"
