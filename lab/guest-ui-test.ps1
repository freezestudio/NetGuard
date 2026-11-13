param(
    [string]$OutDir = 'C:\NetGuard\captures',
    [string]$Password = '1'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$script:LogPath = Join-Path $OutDir 'ui-test.log'
function L($m) {
    $line = "$(Get-Date -Format 'HH:mm:ss.fff')  $m"
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
}
"=== NetGuard UI automation $(Get-Date -Format o) ===" | Set-Content -Path $script:LogPath -Encoding UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class NGWin {
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern bool SetWindowText(IntPtr hWnd, string lpString);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
}
'@
try { [void][NGWin]::SetProcessDPIAware() } catch { }

function WaitCls([string]$cls, [string]$title, [int]$timeoutMs = 20000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $w = [NGWin]::FindWindow($cls, $title)
        if ($w -ne [IntPtr]::Zero -and [NGWin]::IsWindow($w)) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

function Snap($hwnd, [string]$name) {
    if ($hwnd -eq [IntPtr]::Zero -or -not [NGWin]::IsWindow($hwnd)) {
        L "snap $name : window missing"
        return
    }
    [void][NGWin]::ShowWindow($hwnd, 9)
    [void][NGWin]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 650
    $r = New-Object NGWin+RECT
    [void][NGWin]::GetWindowRect($hwnd, [ref]$r)
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $x = [Math]::Max($vs.Left, $r.Left)
    $y = [Math]::Max($vs.Top, $r.Top)
    $w = [Math]::Min($r.Right, $vs.Right) - $x
    $hh = [Math]::Min($r.Bottom, $vs.Bottom) - $y
    if ($w -le 0 -or $hh -le 0) { L "snap $name : bad rect $($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"; return }
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
    $path = Join-Path $OutDir ($name + '.png')
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    L "snap $name -> $path ($w x $hh)"
}

function SetId($hwnd, [int]$id, [string]$text) {
    $c = [NGWin]::GetDlgItem($hwnd, $id)
    if ($c -eq [IntPtr]::Zero) { L "SetId $id : control missing"; return }
    [void][NGWin]::SetWindowText($c, $text)
}

function GetId($hwnd, [int]$id) {
    $c = [NGWin]::GetDlgItem($hwnd, $id)
    if ($c -eq [IntPtr]::Zero) { return '' }
    $sb = New-Object System.Text.StringBuilder 1024
    [void][NGWin]::GetWindowText($c, $sb, 1024)
    return $sb.ToString()
}

function ClickId($hwnd, [int]$id) {
    [void][NGWin]::PostMessage($hwnd, 0x0111, [IntPtr]$id, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 400
}

$exe = Join-Path $PSScriptRoot 'NetGuardUI.exe'
L "exe=$exe exists=$(Test-Path $exe)"
Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot | Out-Null

# 1) 首次设置口令 / 或登录口令
$dlg = WaitCls 'NgInputWnd' '设置管理员口令' 60000
if ($dlg -eq [IntPtr]::Zero) {
    L "no password dialog; maybe admin.dat already exists"
} else {
    L "password dialog shown"
    Snap $dlg '01-password'
    SetId $dlg 100 $Password
    Start-Sleep -Milliseconds 300
    L ("password1=<" + (GetId $dlg 100) + ">")
    ClickId $dlg 1
    Start-Sleep -Seconds 1

    $dlg2 = WaitCls 'NgInputWnd' '确认口令' 30000
    if ($dlg2 -ne [IntPtr]::Zero) {
        L "confirm password dialog shown"
        Snap $dlg2 '02-confirm-password'
        SetId $dlg2 100 $Password
        Start-Sleep -Milliseconds 300
        L ("password2=<" + (GetId $dlg2 100) + ">")
        ClickId $dlg2 1
    }
}

$main = WaitCls 'NetGuardMain' 'NetGuard - 药店终端出网管控' 60000
if ($main -eq [IntPtr]::Zero) {
    L "FATAL: main window not found"
    'FAIL' | Set-Content (Join-Path $OutDir 'ui-test.result') -Encoding ASCII
    exit 1
}
L "main window found"
Snap $main '03-main'

# 2) 业务地址对话框（演示字段，随后取消，不改策略）
ClickId $main 1001
$ep = WaitCls 'NgEntryWnd' '业务地址' 10000
if ($ep -ne [IntPtr]::Zero) {
    SetId $ep 100 '演示前置'
    SetId $ep 101 '10.20.30.40/32'
    SetId $ep 102 '9000-9010'
    SetId $ep 103 'TCP'
    Snap $ep '04-endpoint-dialog'
    ClickId $ep 2
    Start-Sleep -Milliseconds 800
} else { L "endpoint dialog not found" }

# 3) 添加程序：记事本 + 真实 SHA-256，绑定“医保前置”
$note = Join-Path $env:WINDIR 'System32\notepad.exe'
$hash = ''
try { $hash = (Get-FileHash -Algorithm SHA256 -Path $note).Hash } catch { L "Get-FileHash failed: $($_.Exception.Message)" }
ClickId $main 1004
$pr = WaitCls 'NgEntryWnd' '业务程序' 10000
if ($pr -ne [IntPtr]::Zero) {
    SetId $pr 100 '记事本（演示）'
    SetId $pr 101 $note
    SetId $pr 102 $hash
    SetId $pr 103 '医保前置'
    Snap $pr '05-program-dialog'
    ClickId $pr 1
    Start-Sleep -Seconds 1
} else { L "program dialog not found" }
Snap $main '06-main-with-program'

# 4) 保存并应用
ClickId $main 1010
Start-Sleep -Seconds 2
L ("save status: " + (GetId $main 3004))
ClickId $main 1011
Start-Sleep -Seconds 12
$applyStatus = GetId $main 3004
L ("apply status: " + $applyStatus)
Snap $main '07-applied'

# 5) 临时放行 1 分钟
SetId $main 2006 '1'
ClickId $main 1014
Start-Sleep -Seconds 5
$tempStatus = GetId $main 3004
L ("temp status: " + $tempStatus)
Snap $main '08-temp-allow'

# 6) 让窗口保持可见几秒，然后退出
Start-Sleep -Seconds 2
ClickId $main 1017
Start-Sleep -Seconds 1
L "DONE"
'PASS' | Set-Content (Join-Path $OutDir 'ui-test.result') -Encoding ASCII
