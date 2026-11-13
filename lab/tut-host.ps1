# 生成《NetGuard 新手图文教程》所需的真实 Win7 截图
# 运行方式：通过计划任务 VM-Start-Win7 -> elevated-worker.ps1 提权调用
$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\tut-host.log'
$outDir = 'C:\src\NetGuard\lab\tutorial'
$srcDir = 'C:\src\NetGuard\lab\tut'
function L($m) {
    $line = "$(Get-Date -Format 'HH:mm:ss')  $m"
    $line | Out-File $log -Append -Encoding utf8
    Write-Host $line
}
"=== NetGuard 教程截图采集 $(Get-Date -Format o) ===" | Set-Content $log -Encoding utf8
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$vmName = 'Win7-Pro-x64'
$vhd = "C:\VMs\$vmName\disk.vhdx"

# ---------------- 1. 关机 + 挂载磁盘 ----------------
$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') {
    L "VM 状态 $($vm.State)，强制关机"
    Stop-VM -Name $vmName -TurnOff -Force
    Start-Sleep 8
}
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
if (-not (Test-Path "$root\Windows")) { L "ERROR: Windows 分区未找到"; Dismount-VHD -Path $vhd; exit 1 }
L "Windows 分区 = $root"

# ---------------- 2. 清理旧安装 ----------------
foreach ($p in @("$root\NetGuard", "$root\ProgramData\NetGuard")) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue; L "已删除 $p" }
}
$oldVbs = "$root\Users\freeze\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\NetGuardTut.vbs"
if (Test-Path $oldVbs) { Remove-Item $oldVbs -Force -ErrorAction SilentlyContinue; L "已删除旧的启动项" }
Get-ChildItem "$root\Windows\System32\Tasks" -Filter 'Ng*' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    L "已删除计划任务 $($_.Name)"
}

# 服务注册项
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\NG7SYS' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\NG7SYS\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $compName = (Get-ItemProperty "HKLM:\NG7SYS\ControlSet00$cur\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
    foreach ($cs in @($cur, 1, 2)) {
        $svcKey = "HKLM:\NG7SYS\ControlSet00$cs\Services\NetGuard"
        if (Test-Path $svcKey) { Remove-Item $svcKey -Recurse -Force; L "已删除服务注册项 ControlSet00$cs" }
    }
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NG7SYS' 2>&1 | Out-Null
} else { L "SYSTEM hive 加载失败（可忽略）" }

# SOFTWARE：密钥、RunOnce、UAC、自动登录
$swHive = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\NG7SOFT' $swHive 2>&1 | Out-Null
if ($?) {
    if (Test-Path 'HKLM:\NG7SOFT\NetGuard') { Remove-Item 'HKLM:\NG7SOFT\NetGuard' -Recurse -Force; L "已删除 HKLM\SOFTWARE\NetGuard" }

    $sysPol = 'HKLM:\NG7SOFT\Microsoft\Windows\CurrentVersion\Policies\System'
    New-Item -Path $sysPol -Force | Out-Null
    Set-ItemProperty $sysPol -Name EnableLUA -Value 0 -Type DWord
    Set-ItemProperty $sysPol -Name DisableCAD -Value 1 -Type DWord
    $wl = 'HKLM:\NG7SOFT\Microsoft\Windows NT\CurrentVersion\Winlogon'
    New-Item -Path $wl -Force | Out-Null
    Set-ItemProperty $wl -Name AutoAdminLogon -Value '1' -Type String
    Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
    Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
    Set-ItemProperty $wl -Name ForceAutoLogon -Value '1' -Type String
    if ($compName) { Set-ItemProperty $wl -Name DefaultDomainName -Value $compName -Type String }

    $runOnce = 'HKLM:\NG7SOFT\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item -Path $runOnce -Force | Out-Null
    # 教程由宿主机在桌面就绪后驱动，不依赖 RunOnce
    L "免 UAC + 自动登录已配置（教程由宿主机驱动）"

    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NG7SOFT' 2>&1 | Out-Null
} else { L "ERROR: SOFTWARE hive 加载失败"; Dismount-VHD -Path $vhd; exit 1 }

# 控制台窗口：100x40、字号 16、新宋体（截图更清楚）
$userHive = "$root\Users\freeze\NTUSER.DAT"
if (Test-Path $userHive) {
    & reg load 'HKLM\NG7USER' $userHive 2>&1 | Out-Null
    if ($?) {
        $c = 'HKLM:\NG7USER\Console'
        New-Item -Path $c -Force | Out-Null
        $vals = @{
            WindowSize       = 0x00280064
            ScreenBufferSize = 0x012C0064
            FontSize         = 0x00100000
            FontFamily       = 54
            FontWeight       = 400
            FaceName         = '新宋体'
            QuickEdit        = 0
            InsertMode       = 1
        }
        foreach ($k in $vals.Keys) {
            if ($k -eq 'FaceName') { New-ItemProperty -Path $c -Name $k -Value $vals[$k] -PropertyType String -Force | Out-Null }
            else { New-ItemProperty -Path $c -Name $k -Value $vals[$k] -PropertyType DWord -Force | Out-Null }
        }
        [gc]::Collect(); Start-Sleep -Milliseconds 900
        & reg unload 'HKLM\NG7USER' 2>&1 | Out-Null
        L "已设置控制台字体/窗口大小"
    } else { L "NTUSER.DAT 加载失败（使用默认控制台外观）" }
} else { L "未找到 NTUSER.DAT" }

# ---------------- 3. 投放程序与教程脚本 ----------------
$ng = "$root\NetGuard"
New-Item -ItemType Directory -Path "$ng\tut" -Force | Out-Null
foreach ($f in @('NetGuard.exe', 'NetGuardUI.exe')) {
    Copy-Item "C:\src\NetGuard\build\$f" "$ng\$f" -Force
    L "投放 $f $((Get-Item "$ng\$f").Length) 字节"
}
foreach ($f in @('install-netguard.ps1', 'uninstall-netguard.ps1')) {
    Copy-Item "C:\src\NetGuard\$f" "$ng\$f" -Force
    L "投放 $f"
}

$utf8bom = New-Object System.Text.UTF8Encoding($true)
$gbk = [System.Text.Encoding]::GetEncoding(936)
foreach ($f in Get-ChildItem $srcDir -File) {
    $text = [IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($f.Extension -eq '.cmd') {
        [IO.File]::WriteAllText("$ng\tut\$($f.Name)", ($text -replace "`r?`n", "`r`n"), $gbk)
        L "投放 $($f.Name)（GBK）"
    } else {
        [IO.File]::WriteAllText("$ng\tut\$($f.Name)", ($text -replace "`r?`n", "`r`n"), $utf8bom)
        L "投放 $($f.Name)（UTF-8 BOM）"
    }
}

# 登录后从“启动”文件夹自动运行（比 RunOnce 可靠），VBS 隐藏窗口
$startup = "$root\Users\freeze\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Path $startup -Force | Out-Null
$vbs = @'
Set fso = CreateObject("Scripting.FileSystemObject")
Set f = fso.OpenTextFile("C:\NetGuard\tut\boot.log", 8, True)
f.WriteLine "[vbs] " & Now
f.Close
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\NetGuard\tut\run.ps1""", 0, False
'@
[IO.File]::WriteAllText("$startup\NetGuardTut.vbs", ($vbs -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)
L "已部署启动项 NetGuardTut.vbs"

[gc]::Collect()
Dismount-VHD -Path $vhd
L "磁盘已卸载，准备开机"

# ---------------- 4. 启动虚拟机，桌面就绪后由宿主机驱动教程脚本 ----------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class TutVM {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, int e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
function GetVMConsole {
    return Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
function DriveTutorial([string]$why) {
    $vc = GetVMConsole
    if (-not $vc) { L "驱动失败：找不到 VMConnect 窗口"; return }
    $h = $vc.MainWindowHandle
    [void][TutVM]::ShowWindow($h, 9)
    [void][TutVM]::BringWindowToTop($h)
    [void][TutVM]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 800
    $r = New-Object TutVM+RECT
    [void][TutVM]::GetWindowRect($h, [ref]$r)
    [void][TutVM]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int]($r.Top + ($r.Bottom - $r.Top) * 0.45))
    [TutVM]::mouse_event(0x0002, 0, 0, 0, 0)
    [TutVM]::mouse_event(0x0004, 0, 0, 0, 0)
    Start-Sleep -Milliseconds 600
    [System.Windows.Forms.SendKeys]::SendWait('^{ESC}')
    Start-Sleep -Milliseconds 1500
    [System.Windows.Forms.SendKeys]::SendWait('cmd')
    Start-Sleep -Milliseconds 1500
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Seconds 4
    [System.Windows.Forms.SendKeys]::SendWait('powershell -NoProfile -ExecutionPolicy Bypass -File C:\NetGuard\tut\run.ps1')
    Start-Sleep -Milliseconds 600
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    L "已向客人机发送教程启动命令（$why）"
}

Start-VM -Name $vmName
Start-Sleep 3
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
try { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName } catch { L "VMConnect 打开失败: $($_.Exception.Message)" }
L "VM 已启动，等待客人机自动执行教程并关机"

$off = $false
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep 10
    $st = (Get-VM -Name $vmName).State
    if ($i % 6 -eq 0) { L "  T+$(($i + 1) * 10)s state=$st" }
    if ($st -eq 'Off') { $off = $true; L "客人机已关机"; break }
}
if (-not $off) { Stop-VM -Name $vmName -TurnOff -Force; L "超时，强制关机"; Start-Sleep 8 }

# ---------------- 5. 回收截图与日志 ----------------
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"

$dstShots = Join-Path $outDir 'shots'
New-Item -ItemType Directory -Path $dstShots -Force | Out-Null
Get-ChildItem "$root\NetGuard\tut\shots" -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $dstShots $_.Name) -Force
    L "回收截图 $($_.Name) ($($_.Length) 字节)"
}
Get-ChildItem "$root\NetGuard\tut" -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.log', '.txt') } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $outDir $_.Name) -Force
    L "回收日志 $($_.Name)"
}
$dstPd = Join-Path $outDir 'programdata'
New-Item -ItemType Directory -Path $dstPd -Force | Out-Null
Get-ChildItem "$root\ProgramData\NetGuard" -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $dstPd $_.Name) -Force
    L "回收数据 $($_.Name)"
}

L "--- guest.log 末尾 ---"
$gl = Join-Path $outDir 'guest.log'
if (Test-Path $gl) { Get-Content $gl -Encoding UTF8 | Select-Object -Last 40 | ForEach-Object { L "  $_" } }
L "--- ui.log 末尾 ---"
$ul = Join-Path $dstShots 'ui.log'
if (Test-Path $ul) { Get-Content $ul -Encoding UTF8 | Select-Object -Last 30 | ForEach-Object { L "  $_" } }

[gc]::Collect()
Dismount-VHD -Path $vhd
L "DONE"
