Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like '*Win11-Test*' } | Select-Object -First 1
if (-not $vc) { 'no vmconnect'; exit 1 }
$w = New-Object -ComObject WScript.Shell
$w.AppActivate($vc.Id) | Out-Null
Start-Sleep -Milliseconds 700
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
Start-Sleep 3
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save('C:\VMs\iso-rebuild\win11-esc.png', [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
'captured'
