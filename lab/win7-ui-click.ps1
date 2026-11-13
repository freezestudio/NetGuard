$out = 'C:\NetGuard\ui-click-result.txt'
"=== Win7 UI click test $(Get-Date -Format o) ===" | Out-File $out -Encoding utf8
$ui = 'C:\NetGuard\NetGuardUI.exe'
Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
$p = Start-Process $ui -PassThru
"pid=$($p.Id)" | Out-File $out -Append -Encoding utf8

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@

$dlg = [IntPtr]::Zero
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $dlg = [W]::FindWindow('NgInputWnd', $null)
    if ($dlg -ne [IntPtr]::Zero) { break }
}
"dialog=$dlg" | Out-File $out -Append -Encoding utf8

if ($dlg -ne [IntPtr]::Zero) {
    $edit = [W]::FindWindowEx($dlg, [IntPtr]::Zero, 'EDIT', $null)
    $btn  = [W]::FindWindowEx($dlg, [IntPtr]::Zero, 'BUTTON', '确定')
    "edit=$edit button=$btn" | Out-File $out -Append -Encoding utf8
    if ($edit -ne [IntPtr]::Zero) {
        [W]::SendMessage($edit, 0x000C, [IntPtr]::Zero, '1') | Out-Null
    }
    Start-Sleep -Milliseconds 300
    if ($btn -ne [IntPtr]::Zero) {
        [W]::SendMessage($btn, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
    "clicked" | Out-File $out -Append -Encoding utf8
}

$main = [IntPtr]::Zero
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $main = [W]::FindWindow('NetGuardMain', $null)
    if ($main -ne [IntPtr]::Zero) { break }
}
"main=$main" | Out-File $out -Append -Encoding utf8
if ($main -ne [IntPtr]::Zero) { "RESULT=PASS" | Out-File $out -Append -Encoding utf8 }
else { "RESULT=FAIL" | Out-File $out -Append -Encoding utf8 }

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save('C:\NetGuard\ui-click.png', [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    "screenshot=ok" | Out-File $out -Append -Encoding utf8
} catch { "screenshot failed: $($_.Exception.Message)" | Out-File $out -Append -Encoding utf8 }

if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { Stop-Process -Id $p.Id -Force }
"=== done ===" | Out-File $out -Append -Encoding utf8
