$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$vmName = 'Win10-Pro-22H2'
$hostOut = "$RepoRoot\lab\final\win10"
$log = "$RepoRoot\lab\final-win10.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
New-Item -ItemType Directory -Path $hostOut -Force | Out-Null
"=== NetGuard Win10 full clean install $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Running') {
    Start-VM -Name $vmName
    L "VM starting"
    Start-Sleep -Seconds 70
} else {
    L "VM already running"
}

$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop
L "PS Direct session established"

# ---------- 清理旧安装 ----------
$clean = Invoke-Command -Session $s -ScriptBlock {
    $out = @()
    $svc = Get-Service NetGuard -ErrorAction SilentlyContinue
    if ($svc) {
        $out += "old service: $($svc.Status)"
        & sc.exe stop NetGuard | Out-Null
        Start-Sleep 3
        & sc.exe delete NetGuard | Out-Null
        Start-Sleep 2
    }
    Get-Process NetGuard,NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Test-Path 'C:\ProgramData\NetGuard') { Remove-Item 'C:\ProgramData\NetGuard' -Recurse -Force -ErrorAction SilentlyContinue; $out += 'removed ProgramData' }
    if (Test-Path 'C:\NetGuard') { Remove-Item 'C:\NetGuard' -Recurse -Force -ErrorAction SilentlyContinue; $out += 'removed C:\NetGuard' }
    & reg.exe delete 'HKLM\SOFTWARE\NetGuard' /f 2>&1 | Out-Null
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Ng*' } | ForEach-Object {
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        $out += "removed task $($_.TaskName)"
    }
    $out += "service exists after cleanup: " + [bool](Get-Service NetGuard -ErrorAction SilentlyContinue)
    $out += "admin.dat exists: " + (Test-Path 'C:\ProgramData\NetGuard\admin.dat')
    $out
}
$clean | ForEach-Object { L "  $_" }

# ---------- 投放全新构建 ----------
Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null }
Copy-Item "$RepoRoot\build\NetGuard.exe"   -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item "$RepoRoot\build\NetGuardUI.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
Copy-Item "$RepoRoot\install-netguard.ps1" -ToSession $s -Destination 'C:\NetGuard\install-netguard.ps1' -Force
Copy-Item "$RepoRoot\uninstall-netguard.ps1" -ToSession $s -Destination 'C:\NetGuard\uninstall-netguard.ps1' -Force
Copy-Item "$RepoRoot\lab\guest-ui-test.ps1" -ToSession $s -Destination 'C:\NetGuard\guest-ui-test.ps1' -Force
L "files copied"

# ---------- 全新安装 ----------
$inst = Invoke-Command -Session $s -ScriptBlock {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\install-netguard.ps1' 2>&1
    "install_exit=$LASTEXITCODE"
    $o | Select-Object -Last 25
}
$inst | ForEach-Object { L "  $_" }
Start-Sleep -Seconds 5

$st = Invoke-Command -Session $s -ScriptBlock {
    "service=" + (Get-Service NetGuard -ErrorAction SilentlyContinue).Status
    (& cmd.exe /c 'C:\NetGuard\NetGuard.exe ctl status' 2>&1) -join ' / '
}
$st | ForEach-Object { L "  $_" }

# 等看门狗完成一次哈希校验（示例策略里的 YbClient.exe 不存在，会被自动停用）
L "waiting 40s for watchdog/hash pass"
Start-Sleep -Seconds 40

function GuestRun([string]$tag, [string]$cmdline) {
    $r = Invoke-Command -Session $s -ScriptBlock {
        param($c)
        $o = & cmd.exe /c $c 2>&1
        "exit=$LASTEXITCODE"
        $o
    } -ArgumentList $cmdline
    L "--- $tag ---"
    $r | ForEach-Object { L "  $_" }
    return $r
}

GuestRun 'status-after-install' 'C:\NetGuard\NetGuard.exe status' | Out-Null
GuestRun 'ctl-after-install'    'C:\NetGuard\NetGuard.exe ctl status' | Out-Null

# ---------- 功能回归 ----------
GuestRun 'ctl-rollback' 'C:\NetGuard\NetGuard.exe ctl rollback' | Out-Null
Start-Sleep -Seconds 4
GuestRun 'selftest-baseline' 'C:\NetGuard\NetGuard.exe selftest' | Out-Null
GuestRun 'ctl-apply' 'C:\NetGuard\NetGuard.exe ctl apply' | Out-Null
Start-Sleep -Seconds 2
GuestRun 'selftest-applied' 'C:\NetGuard\NetGuard.exe selftest' | Out-Null
GuestRun 'ctl-applied' 'C:\NetGuard\NetGuard.exe ctl status' | Out-Null

GuestRun 'ctl-temp' 'C:\NetGuard\NetGuard.exe ctl temp 1' | Out-Null
Start-Sleep -Seconds 2
GuestRun 'ctl-temp-active' 'C:\NetGuard\NetGuard.exe ctl status' | Out-Null
L "waiting 95s for temp expiry + watchdog"
Start-Sleep -Seconds 95
GuestRun 'ctl-temp-restored' 'C:\NetGuard\NetGuard.exe ctl status' | Out-Null

# ---------- UI 自动化（交互会话） ----------
Invoke-Command -Session $s -ScriptBlock {
    New-Item -ItemType Directory -Path 'C:\NetGuard\captures' -Force | Out-Null
    Remove-Item 'C:\NetGuard\captures\*' -Force -ErrorAction SilentlyContinue
    $tr = 'powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\NetGuard\guest-ui-test.ps1 -OutDir C:\NetGuard\captures'
    & schtasks.exe /create /tn NgUiTest /tr $tr /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f | Out-Null
    & schtasks.exe /run /tn NgUiTest | Out-Null
    "task_started=" + $LASTEXITCODE
}
L "UI task started; waiting for result"
$uiDone = $false
for ($i = 0; $i -lt 48; $i++) {
    Start-Sleep -Seconds 5
    $r = Invoke-Command -Session $s -ScriptBlock {
        if (Test-Path 'C:\NetGuard\captures\ui-test.result') {
            Get-Content 'C:\NetGuard\captures\ui-test.result'
        } else { 'WAIT' }
    }
    if ($r -eq 'PASS' -or $r -eq 'FAIL') { $uiDone = $true; L "UI result=$r"; break }
    if ($i % 4 -eq 0) { L "  UI wait T+$($i*5)s" }
}
if (-not $uiDone) { L "UI automation timed out" }

Invoke-Command -Session $s -ScriptBlock { & schtasks.exe /delete /tn NgUiTest /f 2>&1 | Out-Null }

# 回收截图和日志
try {
    $capOut = Join-Path $hostOut 'captures'
    New-Item -ItemType Directory -Path $capOut -Force | Out-Null
    Copy-Item -FromSession $s -Path 'C:\NetGuard\captures\*' -Destination $capOut -Force -ErrorAction SilentlyContinue
    L "collected captures"
} catch { L "collect captures failed: $($_.Exception.Message)" }
try {
    $pdOut = Join-Path $hostOut 'programdata'
    New-Item -ItemType Directory -Path $pdOut -Force | Out-Null
    Copy-Item -FromSession $s -Path 'C:\ProgramData\NetGuard\*' -Destination $pdOut -Force -ErrorAction SilentlyContinue
    L "collected ProgramData"
} catch { L "collect ProgramData failed: $($_.Exception.Message)" }

# 最终状态：等 UI 里的 1 分钟临时放行到期
L "final wait 90s for UI temp expiry"
Start-Sleep -Seconds 90
GuestRun 'ctl-final' 'C:\NetGuard\NetGuard.exe ctl status' | Out-Null
GuestRun 'status-final' 'C:\NetGuard\NetGuard.exe status' | Out-Null

$uiLog = Join-Path $capOut 'ui-test.log'
if (Test-Path $uiLog) {
    L "--- ui-test.log tail ---"
    Get-Content $uiLog -Encoding UTF8 | Select-Object -Last 40 | ForEach-Object { L "  $_" }
}

Remove-PSSession $s
L "DONE (VM left running)"
