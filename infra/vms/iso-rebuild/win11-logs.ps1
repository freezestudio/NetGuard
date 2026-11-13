Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like '*Win11-Test*' } | Select-Object -First 1
if (-not $vc) { 'no vmconnect'; exit 1 }
$w = New-Object -ComObject WScript.Shell
$w.AppActivate($vc.Id) | Out-Null
Start-Sleep -Milliseconds 800
[System.Windows.Forms.SendKeys]::SendWait('+{F10}')
Start-Sleep 2
[System.Windows.Forms.SendKeys]::SendWait('type X:\Windows\Panther\setuperr.log')
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep 3
[System.Windows.Forms.SendKeys]::SendWait('findstr /i "unattend answer" X:\Windows\Panther\setupact.log')
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep 3
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save('C:\VMs\iso-rebuild\win11-logs.png', [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
'captured'
