$ErrorActionPreference = 'Continue'
$root = 'C:\NetGuard'
$tut = Join-Path $root 'tut'
$shots = Join-Path $tut 'shots'
New-Item -ItemType Directory -Path $shots -Force | Out-Null
$log = Join-Path $tut 'guest.log'
function L($m) {
    $line = "$(Get-Date -Format 'HH:mm:ss')  $m"
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
"=== NetGuard Win7 教程截图 $(Get-Date -Format o) ===" | Set-Content -Path $log -Encoding UTF8

# 防止重复启动（宿主机可能重发一次驱动命令）
$lock = Join-Path $tut 'running.lock'
if (Test-Path $lock) { L "already running (lock present), exit"; exit 0 }
Set-Content -Path $lock -Value (Get-Date -Format o) -Encoding ASCII
L "lock created; PS " + $PSVersionTable.PSVersion.ToString()

# 1. 等桌面就绪
for ($i = 0; $i -lt 90; $i++) {
    if (Get-Process explorer -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 10
L "desktop ready"

try {
    & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $tut 'shot.ps1') -Name '01-desktop' -FullScreen
} catch { L "desktop shot failed: $($_.Exception.Message)" }

# 2. 开始菜单（如果能调出来就截图，调不出来不影响教程）
try {
    $ws = New-Object -ComObject WScript.Shell
    $ws.SendKeys('^{ESC}')
    Start-Sleep -Seconds 2
    & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $tut 'shot.ps1') -Name '02-start-menu' -FullScreen
    $ws.SendKeys('{ESC}')
    Start-Sleep -Seconds 1
} catch { L "start menu shot failed: $($_.Exception.Message)" }

# 3. 第一阶段：命令行安装（截图在 step1.cmd 内完成）
L "run step1.cmd"
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', (Join-Path $tut 'step1.cmd') -WorkingDirectory $root -PassThru
$p.WaitForExit()
L "step1 exit=$($p.ExitCode)"

# 4. 第二阶段：管理界面
L "run ui.ps1"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tut\ui.ps1`" -OutDir `"$shots`""
$psi.UseShellExecute = $false
$p2 = [System.Diagnostics.Process]::Start($psi)
$p2.WaitForExit()
L "ui exit=$($p2.ExitCode)"
Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# 5. 第三阶段：验证/临时放行/审计/卸载
L "run step3.cmd"
$p3 = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', (Join-Path $tut 'step3.cmd') -WorkingDirectory $root -PassThru
$p3.WaitForExit()
L "step3 exit=$($p3.ExitCode)"

# 6. 结果清单
$files = Get-ChildItem $shots -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Sort-Object Name
"shots=$($files.Count)" | Add-Content $log -Encoding UTF8
foreach ($f in $files) { "  $($f.Name) $($f.Length)" | Add-Content $log -Encoding UTF8 }

L "done; shutting down"
$startupVbs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\NetGuardTut.vbs'
if (Test-Path $startupVbs) { Remove-Item $startupVbs -Force -ErrorAction SilentlyContinue }
shutdown.exe /s /t 20 /f
exit 0
