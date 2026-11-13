$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$log="$RepoRoot\lab\sendkeys.log"
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== VMConnect + SendKeys 测试 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
}
'@

$vmName='Win7-Pro-x64'
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue
if (-not $vc) {
    Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
    L "已启动 VMConnect"
    Start-Sleep -Seconds 10
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue
}
if (-not $vc) { L "VMConnect 未启动"; exit 1 }
foreach ($p in $vc) { L "  vmconnect pid=$($p.Id) title='$($p.MainWindowTitle)' hwnd=$($p.MainWindowHandle)" }

$h = ($vc | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1).MainWindowHandle
if (-not $h) { L "找不到主窗口"; exit 1 }
[W]::ShowWindow($h, 9) | Out-Null       # SW_RESTORE
[W]::BringWindowToTop($h) | Out-Null
[W]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800
L "前台窗口 hwnd=$([W]::GetForegroundWindow())"

# 截图（WMI 缩略图）
Add-Type -AssemblyName System.Drawing
$cs=Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc=Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
function Cap($tag){
  $res=Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{TargetSystem=$cs;WidthPixels=[uint16]800;HeightPixels=[uint16]600}
  if($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0){
    $bmp=New-Object System.Drawing.Bitmap(800,600,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $r=New-Object System.Drawing.Rectangle(0,0,800,600)
    $d=$bmp.LockBits($r,[System.Drawing.Imaging.ImageLockMode]::WriteOnly,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData,0,$d.Scan0,$res.ImageData.Length)
    $bmp.UnlockBits($d); $bmp.Save("$RepoRoot\lab\sk-$tag.png",[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    L "  截图 sk-$tag.png"
  }
}
Cap 'before'
L "发送 {ENTER}"
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep -Seconds 6
Cap 'after'
L "完成"
