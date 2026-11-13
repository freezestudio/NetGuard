$ErrorActionPreference = 'Continue'
. 'C:\src\NetGuard\lab\ng-lab-common.ps1'
$log = 'C:\src\NetGuard\lab\test-win10.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win10 22H2 上的 NetGuard 验证 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$vm = Get-VM -Name $vmName
L "VM 状态: $($vm.State)"
if ($vm.State -ne 'Running') { Start-VM -Name $vmName; Start-Sleep 45; L "已启动" }

$sec = ConvertTo-SecureString '1' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('freeze', $sec)

# 1) 投放文件
try {
    $s = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop
    L "PS Direct 会话已建立"
} catch {
    L "PS Direct 失败: $($_.Exception.Message)"
    exit 1
}

Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 1
    & sc.exe delete NetGuard 2>&1 | Out-Null
    Get-Process NetGuard -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    New-Item -ItemType Directory -Path C:\NetGuard -Force | Out-Null
    New-Item -ItemType Directory -Path C:\ProgramData\NetGuard -Force | Out-Null
}
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe' -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
L "已投放 NetGuard.exe"

$policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=医保前置
Cidr=10.10.10.10/32
Ports=8000-8005
Proto=TCP
Enable=1

[proc.1]
Name=记事本（占位进程）
Path=C:\Windows\System32\notepad.exe
Sha256=
Endpoint=医保前置
Enable=1
"@
$tmp = 'C:\src\NetGuard\lab\policy-win10.ini'
[IO.File]::WriteAllText($tmp, ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item $tmp -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
L "已投放 policy.ini"
Sign-NgGuestPolicy -Session $s | ForEach-Object { L "  $_" }

# 2) 逐步执行并收集输出
function RunIn($desc, $cmd) {
    L "--- $desc ---"
    try {
        $out = Invoke-Command -Session $s -ScriptBlock { param($c) & cmd.exe /c $c 2>&1 } -ArgumentList $cmd
        $out | ForEach-Object { L "  $_" }
    } catch { L "  执行失败: $($_.Exception.Message)" }
}

RunIn 'whoami（确认会话身份）' 'whoami'
RunIn '基线自检（应能连出去）' 'C:\NetGuard\NetGuard.exe selftest'
RunIn 'apply（下发默认拒绝）' 'C:\NetGuard\NetGuard.exe apply'
RunIn '应用后自检（应全部拦截）' 'C:\NetGuard\NetGuard.exe selftest'
RunIn 'status' 'C:\NetGuard\NetGuard.exe status'
RunIn 'rollback' 'C:\NetGuard\NetGuard.exe rollback'
RunIn '回滚后自检（应恢复连接）' 'C:\NetGuard\NetGuard.exe selftest'

Remove-PSSession $s
L "完成"
