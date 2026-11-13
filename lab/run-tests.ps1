$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
. "$RepoRoot\lab\ng-lab-common.ps1"
$log = "$RepoRoot\lab\run-tests.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== NetGuard 端到端测试 (Win10 22H2) ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Running') { Start-VM -Name $vmName; Start-Sleep 45 }
L "VM 状态: $((Get-VM -Name $vmName).State)"

$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
try { $s = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop }
catch { L "PS Direct 失败: $($_.Exception.Message)"; exit 1 }

# ---- 部署 ----
Invoke-Command -Session $s -ScriptBlock {
    # 保证基线干净：停掉/清理可能残留的服务进程（会话级过滤器随进程退出）
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 1
    & sc.exe delete NetGuard 2>&1 | Out-Null
    Get-Process NetGuard -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null
    New-Item -ItemType Directory -Path 'C:\ProgramData\NetGuard' -Force | Out-Null
}
Copy-Item "$RepoRoot\build\NetGuard.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item "$RepoRoot\lab\policy-win10.ini" -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
Invoke-Command -Session $s -ScriptBlock {
    Remove-Item 'C:\ProgramData\NetGuard\ng.log', 'C:\ProgramData\NetGuard\filters.txt' -ErrorAction SilentlyContinue
    Get-ChildItem 'C:\ProgramData\NetGuard' | Select-Object Name, Length
} | ForEach-Object { L "  已部署: $_" }
Sign-NgGuestPolicy -Session $s | ForEach-Object { L "  $_" }

# ---- 执行 + 收集 ----
function Step($title, $exeArgs) {
    L "--- $title ---"
    $r = Invoke-Command -Session $s -ScriptBlock {
        param($a)
        $out = 'C:\NetGuard\step.txt'
        Remove-Item $out -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath 'C:\NetGuard\NetGuard.exe' -ArgumentList $a -NoNewWindow -Wait -PassThru `
             -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        "exit=$($p.ExitCode)"
        if (Test-Path $out) { Get-Content $out -Encoding Default }
        if (Test-Path "$out.err") { Get-Content "$out.err" -Encoding Default }
    } -ArgumentList $exeArgs
    $r | ForEach-Object { L "  $_" }
    $l = Invoke-Command -Session $s -ScriptBlock {
        if (Test-Path 'C:\ProgramData\NetGuard\ng.log') { Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 | Select-Object -Last 4 }
    }
    $l | ForEach-Object { L "    log: $_" }
}

Step '1. selftest（基线，应能连出去 exit=2）' 'selftest'
Step '2. apply（下发默认拒绝）' 'apply'
Step '3. selftest（应全部拦截 exit=0）' 'selftest'
Step '4. status' 'status'
Step '5. 手工验证：读取 filters.txt（生效清单）' 'status'
Invoke-Command -Session $s -ScriptBlock {
    if (Test-Path 'C:\ProgramData\NetGuard\filters.txt') { "filters.txt 行数=" + (Get-Content 'C:\ProgramData\NetGuard\filters.txt').Count }
} | ForEach-Object { L "  $_" }
Step '6. rollback' 'rollback'
Step '7. selftest（回滚后应恢复 exit=2）' 'selftest'

Remove-PSSession $s
L "完成"
