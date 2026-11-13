param(
    [string]$OutDir = 'C:\NetGuard\tut\shots',
    [string]$Password = '1'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$script:LogPath = Join-Path $OutDir 'ui.log'
function L($m) {
    $line = "$(Get-Date -Format 'HH:mm:ss.fff')  $m"
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
}
"=== NetGuard UI automation $(Get-Date -Format o) ===" | Set-Content -Path $script:LogPath -Encoding UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
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
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
}
'@

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
    if ($hwnd -eq [IntPtr]::Zero -or -not [NGWin]::IsWindow($hwnd)) { L "snap $name : window missing"; return }
    [void][NGWin]::ShowWindow($hwnd, 9)
    [void][NGWin]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 700
    $r = New-Object NGWin+RECT
    [void][NGWin]::GetWindowRect($hwnd, [ref]$r)
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $x = [Math]::Max($vs.Left, $r.Left)
    $y = [Math]::Max($vs.Top, $r.Top)
    $w = [Math]::Min($r.Right, $vs.Right) - $x
    $h = [Math]::Min($r.Bottom, $vs.Bottom) - $y
    if ($w -le 0 -or $h -le 0) { L "snap $name : bad rect"; return }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
    $path = Join-Path $OutDir ($name + '.png')
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    L "snap $name -> $path ($w x $h)"
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
    Start-Sleep -Milliseconds 600
}

# Win7 上跨进程 SetWindowText 写 EDIT 不生效；改成“置前 + 键盘输入”
function EnsureForeground($hwnd) {
    [void][NGWin]::ShowWindow($hwnd, 9)
    [void][NGWin]::BringWindowToTop($hwnd)
    for ($i = 0; $i -lt 20; $i++) {
        [void][NGWin]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 200
        if ([NGWin]::GetForegroundWindow() -eq $hwnd) { return $true }
    }
    return $false
}

function FillFields($hwnd, [string[]]$vals) {
    $fg = EnsureForeground $hwnd
    L "FillFields foreground=$fg fields=$($vals.Count)"
    Start-Sleep -Milliseconds 500
    for ($i = 0; $i -lt $vals.Count; $i++) {
        if ($i -gt 0) {
            [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
            Start-Sleep -Milliseconds 250
        }
        # 全选原内容再输入，避免默认值残留
        [System.Windows.Forms.SendKeys]::SendWait('{END}')
        [System.Windows.Forms.SendKeys]::SendWait('+{HOME}')
        Start-Sleep -Milliseconds 120
        [System.Windows.Forms.SendKeys]::SendWait($vals[$i])
        Start-Sleep -Milliseconds 250
    }
    L "FillFields done"
}

$exe = 'C:\NetGuard\NetGuard.exe'
$ui = 'C:\NetGuard\NetGuardUI.exe'
L "ui exists=$(Test-Path $ui)"
Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Start-Process -FilePath $ui -WorkingDirectory 'C:\NetGuard' | Out-Null

# 1) 首次设置管理员口令
$dlg = WaitCls 'NgInputWnd' '设置管理员口令' 60000
if ($dlg -eq [IntPtr]::Zero) {
    L "no password dialog; maybe admin.dat already exists"
} else {
    L "password dialog shown"
    Start-Sleep -Milliseconds 800
    Snap $dlg '11-ui-password'
    FillFields $dlg @($Password)
    Snap $dlg '11-ui-password-filled'
    ClickId $dlg 1
    Start-Sleep -Seconds 2

    $dlg2 = WaitCls 'NgInputWnd' '确认口令' 30000
    if ($dlg2 -ne [IntPtr]::Zero) {
        L "confirm password dialog shown"
        Start-Sleep -Milliseconds 800
        Snap $dlg2 '12-ui-password-confirm'
        FillFields $dlg2 @($Password)
        Snap $dlg2 '12-ui-password-confirm-filled'
        ClickId $dlg2 1
        Start-Sleep -Seconds 2
    }
    $err = [NGWin]::FindWindow('#32770', 'NetGuard')
    if ($err -ne [IntPtr]::Zero) {
        L "ERROR dialog: passwords did not match"
        [void][NGWin]::PostMessage($err, 0x0100, [IntPtr]0x0D, [IntPtr]::Zero)
        Start-Sleep -Seconds 1
    }
}

$main = WaitCls 'NetGuardMain' 'NetGuard - 药店终端出网管控' 60000
if ($main -eq [IntPtr]::Zero) {
    L "FATAL: main window not found"
    'FAIL' | Set-Content (Join-Path $OutDir 'ui.result') -Encoding ASCII
    exit 1
}
L "main window found"
Snap $main '13-ui-main'

# 2) 新增业务地址
ClickId $main 1001
$ep = WaitCls 'NgEntryWnd' '业务地址' 10000
if ($ep -ne [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 600
    FillFields $ep @('EP-Demo', '10.20.30.40/32', '9000-9010', 'TCP')
    Snap $ep '14-ui-endpoint'
    ClickId $ep 1
    Start-Sleep -Milliseconds 900
} else { L "endpoint dialog not found" }

# 3) 新增业务程序：记事本 + 真实 SHA-256，绑定到 EP-Demo
$note = Join-Path $env:WINDIR 'System32\notepad.exe'
$hash = ''
try { $hash = ((& $exe hash $note) | Out-String).Trim() } catch { L "hash cmd failed: $($_.Exception.Message)" }
if ($hash -notmatch '^[0-9A-Fa-f]{64}$') {
    try {
        $o = & certutil.exe -hashfile $note SHA256
        $line = $o | Where-Object { $_ -match '^[0-9a-fA-F ]{60,}$' } | Select-Object -First 1
        if ($line) { $hash = ($line -replace ' ', '') }
    } catch { }
}
L "notepad hash=$hash"
ClickId $main 1004
$pr = WaitCls 'NgEntryWnd' '业务程序' 10000
if ($pr -ne [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 600
    FillFields $pr @('Notepad-Demo', $note, $hash, 'EP-Demo')
    Snap $pr '15-ui-program'
    ClickId $pr 1
    Start-Sleep -Seconds 1
} else { L "program dialog not found" }

# 4) 保存并应用
ClickId $main 1010
Start-Sleep -Seconds 2
L ("save status: " + (GetId $main 3004))
ClickId $main 1011
Start-Sleep -Seconds 15
L ("apply status: " + (GetId $main 3004))
Snap $main '16-ui-applied'

Start-Sleep -Seconds 2
ClickId $main 1017
Start-Sleep -Seconds 1
L "DONE"
'PASS' | Set-Content (Join-Path $OutDir 'ui.result') -Encoding ASCII
