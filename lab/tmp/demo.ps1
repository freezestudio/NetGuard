$ErrorActionPreference = 'Continue'
$dir    = 'C:\NetGuard'
$ng     = "$dir\NetGuard.exe"
$curl   = 'C:\Windows\System32\curl.exe'
$shots  = "$dir\demo-shots"
$steps  = "$shots\steps.txt"
New-Item -ItemType Directory -Path $shots -Force | Out-Null
Remove-Item "$shots\*.png" -Force -ErrorAction SilentlyContinue
Remove-Item $steps -Force -ErrorAction SilentlyContinue
function Log($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $steps -Append -Encoding ascii }
function Shot($n) {
    Start-Sleep -Milliseconds 1200   # 等 conhost/GDI 把上一批输出真正画到屏幕上
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
    $bmp.Save("$shots\$n.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Log "shot $n"
}
function Say($t) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host (' ' + $t) -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}
function Curb($url) {
    $o = & $curl -s -o NUL -m 6 --connect-timeout 4 $url 2>&1
    $c = $LASTEXITCODE
    if ($c -eq 7) { Write-Host ("  curl -> exit=$c  << 无法建立连接，已被拦截") -ForegroundColor Green }
    elseif ($c -eq 35 -or $c -eq 28 -or $c -eq 0 -or $c -eq 52 -or $c -eq 56) {
        Write-Host ("  curl -> exit=$c  << TCP 已连通（未拦截；35/28 只是 TLS/超时）") -ForegroundColor Yellow
    } else { Write-Host ("  curl -> exit=$c") -ForegroundColor Gray }
    return $c
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
}
'@
try {
    $ru = $Host.UI.RawUI
    $ru.WindowTitle = 'NetGuard 演示 (管理员)'
    $ru.BufferSize = New-Object Management.Automation.Host.Size(120, 2000)
    $ru.WindowSize = New-Object Management.Automation.Host.Size(120, 36)
} catch {}
try { (New-Object -ComObject Shell.Application).MinimizeAll() } catch {}
Start-Sleep 1
$h = [W]::GetConsoleWindow()
[W]::ShowWindow($h, 9) | Out-Null
[W]::SetForegroundWindow($h) | Out-Null

Clear-Host
Write-Host 'NetGuard 药店终端出网白名单 - 现场演示' -ForegroundColor White
Write-Host '机器: Win10 22H2 客户机 / 账户 freeze / 服务 NetGuard (LocalSystem)' -ForegroundColor Gray
Log 'demo start'
Start-Sleep 4
Shot '01-desktop'

Say '1) 当前策略状态（默认拒绝已生效）'
& $ng ctl status
Shot '02-status'
Start-Sleep 7

Say '2) 未授权程序访问外网：应被拦截（curl exit=7）'
Curb 'https://8.8.8.8:53/' | Out-Null
Shot '03-blocked'
Start-Sleep 7

Say '3) 派工单：临时撤销管控（ctl rollback）-> 联网恢复'
& $ng ctl rollback
Curb 'https://8.8.8.8:53/' | Out-Null
Shot '04-rollback'
Start-Sleep 7

Say '4) 工作完成：重新下发策略（ctl apply）-> 再次拦截'
& $ng ctl apply
Curb 'https://8.8.8.8:53/' | Out-Null
Shot '05-reapplied'
Start-Sleep 7

Say '5) 端到端自检（5 个外网目标应全部拦截）'
& $ng selftest
Shot '06-selftest'
Start-Sleep 7

Say '6) 临时放行 1 分钟（给更新程序用），到期后看门狗自动恢复'
& $ng ctl temp 1
Start-Sleep 3
& $ng ctl status | Select-String 'filters|filters_live|temp_until'
Curb 'https://8.8.8.8:53/' | Out-Null
Shot '07-temp'
for ($i = 60; $i -ge 1; $i -= 10) {
    Write-Host ("  等待到期并自动恢复 ... 剩余约 {0} 秒" -f $i) -ForegroundColor DarkYellow
    Start-Sleep 10
}
Start-Sleep 8
Write-Host '  看门狗已自动恢复：' -ForegroundColor DarkYellow
& $ng ctl status | Select-String 'filters=|filters_live|default_deny|temp_until'
Curb 'https://8.8.8.8:53/' | Out-Null
Shot '08-temp-restored'
Start-Sleep 6

Say '7) 打开管理界面（业务地址 / 业务程序 / 哈希 / 临时放行）'
Start-Process -FilePath "$dir\NetGuardUI.exe" -ArgumentList '--password1'
Start-Sleep 6
# 把界面窗口挪到 (0,0) 并缩到屏幕内，便于肉眼和截图完整查看
Add-Type @'
using System; using System.Runtime.InteropServices;
public class N {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
$ui = Get-Process NetGuardUI -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ui -and $ui.MainWindowHandle -ne 0) {
    [N]::SetWindowPos($ui.MainWindowHandle, [IntPtr]::Zero, 0, 0, 1360, 730, 0x0040) | Out-Null
    [N]::SetForegroundWindow($ui.MainWindowHandle) | Out-Null
    Log ("ui window placed: " + $ui.MainWindowHandle)
} else { Log 'ui window not found' }
Start-Sleep 3
Shot '09-ui'
Start-Sleep 8
Shot '10-ui-final'
Log 'demo done'
Write-Host ''
Write-Host '演示结束。窗口保留，可直接查看状态栏与各按钮。' -ForegroundColor White
