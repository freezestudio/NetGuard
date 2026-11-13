# 在 Win10 客户机的“交互桌面”里跑一遍演示：可见的命令行窗口 + 管理界面 + 截图。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File C:\src\NetGuard\lab\interactive-demo-win10.ps1
$ErrorActionPreference = 'Stop'
$vm    = 'Win10-Pro-22H2'
$lab   = 'C:\src\NetGuard\lab'
$shots = Join-Path $lab 'shots'
New-Item -ItemType Directory -Path $shots -Force | Out-Null

$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
if ((Get-VM $vm).State -ne 'Running') { Start-VM $vm; Start-Sleep 40 }
$s = New-PSSession -VMName $vm -Credential $cred

Copy-Item (Join-Path $lab 'tmp\demo.ps1') -ToSession $s -Destination 'C:\NetGuard\demo.ps1' -Force
Copy-Item (Join-Path $lab 'admin.dat')    -ToSession $s -Destination 'C:\ProgramData\NetGuard\admin.dat' -Force
Invoke-Command -Session $s -ScriptBlock {
    & icacls 'C:\ProgramData\NetGuard\admin.dat' /inheritance:r | Out-Null
    & icacls 'C:\ProgramData\NetGuard\admin.dat' /grant '*S-1-5-18:F' | Out-Null
    & icacls 'C:\ProgramData\NetGuard\admin.dat' /grant '*S-1-5-32-544:F' | Out-Null
}

# 在交互会话（session 1）以最高权限启动，窗口用户可见，且不会弹 UAC
$tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File C:\NetGuard\demo.ps1'
Invoke-Command -Session $s -ScriptBlock {
    param($tr)
    & schtasks.exe /delete /tn NG-Demo /f 2>&1 | Out-Null
    & schtasks.exe /create /tn NG-Demo /tr $tr /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
    & schtasks.exe /run /tn NG-Demo 2>&1 | Out-Null
} -ArgumentList $tr

# 等待演示结束（脚本最后写 demo done）
$done = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep 5
    $st = Invoke-Command -Session $s -ScriptBlock {
        if (Test-Path 'C:\NetGuard\demo-shots\steps.txt') { Get-Content 'C:\NetGuard\demo-shots\steps.txt' -Encoding ascii } else { @() }
    }
    if ($st -match 'demo done') { $done = $true; break }
}
Invoke-Command -Session $s -ScriptBlock { & schtasks.exe /delete /tn NG-Demo /f 2>&1 | Out-Null }

# 把截图和步骤记录取回宿主
Remove-Item (Join-Path $shots '*.png') -Force -ErrorAction SilentlyContinue
$names = @('01-desktop','02-status','03-blocked','04-rollback','05-reapplied','06-selftest','07-temp','08-temp-restored','09-ui','10-ui-final')
foreach ($n in $names) {
    try {
        Copy-Item -FromSession $s -Path "C:\NetGuard\demo-shots\$n.png" -Destination (Join-Path $shots "$n.png") -Force -ErrorAction Stop
        Write-Host ("[ok] {0}.png  {1:N0} bytes" -f $n, (Get-Item (Join-Path $shots "$n.png")).Length)
    } catch { Write-Host ("[miss] {0}.png" -f $n) }
}
try {
    Copy-Item -FromSession $s -Path 'C:\NetGuard\demo-shots\steps.txt' -Destination (Join-Path $shots 'steps.txt') -Force
} catch {}

# 把宿主上的 VMConnect 窗口提到前台，方便直接观看
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vm*" } | Select-Object -First 1
if ($vc) {
    $sig = @'
using System; using System.Runtime.InteropServices;
public class F { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
'@
    Add-Type $sig
    [F]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [F]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
}
$final = Invoke-Command -Session $s -ScriptBlock {
    $o = 'C:\ProgramData\NetGuard\demo-final.out'
    $p = Start-Process 'C:\NetGuard\NetGuard.exe' -ArgumentList 'ctl status' -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o
    $t = Get-Content $o -Encoding Default
    Remove-Item $o -Force
    $t
}
Remove-PSSession $s
Write-Host ''
Write-Host ("demo finished: {0}" -f $done)
$final
