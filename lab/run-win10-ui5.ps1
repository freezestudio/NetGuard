$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\run-win10-ui5.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== UI5 $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred -ErrorAction Stop
Copy-Item 'C:\src\NetGuard\lab\guest-ui-test.ps1' -ToSession $s -Destination 'C:\NetGuard\guest-ui-test.ps1' -Force
$r = Invoke-Command -Session $s -ScriptBlock {
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item 'C:\ProgramData\NetGuard\admin.dat' -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path 'C:\NetGuard\captures' -Force | Out-Null
    Remove-Item 'C:\NetGuard\captures\*' -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'NgUiTest' -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\NetGuard\guest-ui-test.ps1 -OutDir C:\NetGuard\captures'
    $prin = New-ScheduledTaskPrincipal -UserId 'freeze' -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'NgUiTest' -Action $action -Principal $prin -Force | Out-Null
    Start-ScheduledTask -TaskName 'NgUiTest'
    'started'
}
$r | ForEach-Object { L "$_" }
$done = $false
for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Seconds 5
    $res = Invoke-Command -Session $s -ScriptBlock {
        if (Test-Path 'C:\NetGuard\captures\ui-test.result') { Get-Content 'C:\NetGuard\captures\ui-test.result' } else { 'WAIT' }
    }
    if ($res -eq 'PASS' -or $res -eq 'FAIL') { L "UI result=$res"; $done = $true; break }
    if ($i % 6 -eq 0) { L "  wait T+$($i*5)s" }
}
if (-not $done) { L 'UI timed out' }
$capOut = 'C:\src\NetGuard\lab\final\win10\captures'
New-Item -ItemType Directory -Path $capOut -Force | Out-Null
Copy-Item -FromSession $s -Path 'C:\NetGuard\captures\*' -Destination $capOut -Force -ErrorAction SilentlyContinue
L 'captures copied'
Remove-PSSession $s
'DONE' | Out-File $log -Append -Encoding utf8
