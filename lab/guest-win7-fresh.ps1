$ErrorActionPreference = 'Continue'
$root = 'C:\NetGuard'
$out  = Join-Path $root 'final'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$log = Join-Path $out 'guest.log'
function L($m) {
    $line = "$(Get-Date -Format 'HH:mm:ss')  $m"
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
"=== NetGuard Win7 fresh install + regression $(Get-Date -Format o) ===" | Set-Content -Path $log -Encoding UTF8
L ("PS version: " + $PSVersionTable.PSVersion.ToString())
L ("OS: " + (Get-WmiObject Win32_OperatingSystem).Caption)

# 等桌面/网络就绪
for ($i = 0; $i -lt 60; $i++) {
    if (Get-Process explorer -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 8
L "desktop ready"

# 等 DHCP/默认路由就绪，否则“基线能连出去”的判定会误报
for ($i = 0; $i -lt 30; $i++) {
    $gw = (Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=1' -ErrorAction SilentlyContinue |
           Where-Object { $_.DefaultIPGateway } | Select-Object -First 1)
    if ($gw) { L "network ready: $($gw.DefaultIPGateway -join ',')"; break }
    Start-Sleep -Seconds 2
}

function Run([string]$tag, [string]$exe, [string]$argline) {
    $file = Join-Path $out ($tag + '.txt')
    $line = '& ' + '"' + $exe + '" ' + $argline + ' *> ' + '"' + $file + '"' + '; exit $LASTEXITCODE'
    $code = 0
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $line
        ) -Wait -PassThru -WindowStyle Hidden
        $code = $p.ExitCode
    } catch {
        L "$tag launch failed: $($_.Exception.Message)"
    }
    L "$tag exit=$code"
    if (Test-Path $file) {
        Get-Content $file -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { L "  $_" }
    }
    return $code
}

# 1) 全新安装（安装脚本内部会 initkey/initpolicy/verify/install/start）
L "running install-netguard.ps1"
$installLog = Join-Path $out 'install.log'
$code = 0
try {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'install-netguard.ps1')
    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $installLog -RedirectStandardError ($installLog + '.err')
    $code = $p.ExitCode
} catch {
    L "install failed: $($_.Exception.Message)"
}
L "install exit=$code"
if (Test-Path $installLog) {
    Get-Content $installLog -ErrorAction SilentlyContinue | ForEach-Object { L "  $_" }
}
if (Test-Path ($installLog + '.err')) {
    Get-Content ($installLog + '.err') -ErrorAction SilentlyContinue | ForEach-Object { L "  ERR $_" }
}

$exe = Join-Path $root 'NetGuard.exe'
L "service status: $((Get-Service NetGuard -ErrorAction SilentlyContinue).Status)"
Run '01-status-installed' $exe 'status'
Run '02-ctl-installed'  $exe 'ctl status'

# 2) 回滚 -> 基线连通性 -> 再应用
Run '03-ctl-rollback' $exe 'ctl rollback'
Start-Sleep -Seconds 4
Run '04-selftest-baseline' $exe 'selftest'
Start-Sleep -Seconds 2
Run '05-ctl-apply' $exe 'ctl apply'
Start-Sleep -Seconds 2
Run '06-selftest-applied' $exe 'selftest'
Run '07-ctl-applied' $exe 'ctl status'

# 3) 临时放行 1 分钟 + 看门狗自动恢复
Run '08-ctl-temp' $exe 'ctl temp 1'
Start-Sleep -Seconds 2
Run '09-ctl-temp-active' $exe 'ctl status'
L "sleeping 95s for temp expiry + watchdog"
Start-Sleep -Seconds 95
Run '10-ctl-temp-restored' $exe 'ctl status'

# 4) 管理界面：首次口令 + 主界面 + 编辑对话框 + 保存应用 + 临时放行
L "starting UI automation"
$uiLog = Join-Path $out 'ui-automation.log'
try {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'guest-ui-test.ps1'),
        '-OutDir', (Join-Path $root 'captures')
    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $uiLog -RedirectStandardError ($uiLog + '.err')
    L "ui exit=$($p.ExitCode)"
} catch {
    L "ui failed: $($_.Exception.Message)"
}
if (Test-Path $uiLog) { Get-Content $uiLog | ForEach-Object { L "  UI $_" } }
if (Test-Path ($uiLog + '.err')) { Get-Content ($uiLog + '.err') | ForEach-Object { L "  UIERR $_" } }

Run '11-ctl-final' $exe 'ctl status'
Run '12-status-final' $exe 'status'

L "done; shutting down for offline collection"
shutdown.exe /s /t 20 /f
