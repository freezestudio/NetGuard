$VmsRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$log = "$VmsRoot\iso-rebuild\win11-boot-key2.log"
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== boot key2 ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$name = 'Win11-Test'
$win11 = "$VmsRoot\iso-rebuild\Win11-EnterpriseEval-24H2-en-us.iso"
$answer = "$VmsRoot\iso-rebuild\autounattend-win11.iso"

$dvds = @(Get-VMDvdDrive -VMName $name)
if (-not ($dvds | Where-Object { $_.Path -eq $answer })) {
    Add-VMDvdDrive -VMName $name -Path $answer | Out-Null
    L 'answer DVD added'
}
$win = Get-VMDvdDrive -VMName $name | Where-Object { $_.Path -eq $win11 } | Select-Object -First 1
Set-VMFirmware -VMName $name -FirstBootDevice $win
Get-VMDvdDrive -VMName $name | Select-Object ControllerNumber,ControllerLocation,Path | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
L ('SecureBoot=' + (Get-VMFirmware -VMName $name).SecureBoot)

if (-not (Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*Win11-Test*' })) {
    Start-Process vmconnect.exe -ArgumentList 'localhost', $name
    Start-Sleep 5
}

Start-VM -Name $name
Add-Type -AssemblyName System.Windows.Forms
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep 1
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like '*Win11-Test*' } | Select-Object -First 1
    if ($vc) {
        $w = New-Object -ComObject WScript.Shell
        $w.AppActivate($vc.Id) | Out-Null
        [System.Windows.Forms.SendKeys]::SendWait(' ')
    }
}
L 'sent space keys for 25s'
Set-Content "$VmsRoot\iso-rebuild\win11-boot-key2-done.txt" (Get-Date -Format o) -Encoding UTF8
