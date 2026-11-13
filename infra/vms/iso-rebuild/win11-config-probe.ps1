$ErrorActionPreference = 'Continue'
$log = 'C:\VMs\iso-rebuild\win11-config-probe.log'
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== Win11 config probe ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = $null
for ($i=0; $i -lt 20; $i++) {
    try { $s = New-PSSession -VMName 'Win11-Test' -Credential $cred -ErrorAction Stop; break } catch { Start-Sleep 5 }
}
if (-not $s) { L 'PS Direct FAILED'; Set-Content 'C:\VMs\iso-rebuild\win11-config-probe-done.txt' (Get-Date -Format o); exit 1 }
L 'PS Direct connected'
$r = Invoke-Command -Session $s -ScriptBlock {
    [pscustomobject]@{
        Who = (whoami)
        OS = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber | Out-String)
        Users = ((Get-LocalUser | Select-Object Name,Enabled | Format-Table -AutoSize | Out-String))
        Bcd = ((& bcdedit.exe /enum '{current}' 2>&1) -join "`n")
        DG = ((Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard | Select-Object VirtualizationBasedSecurityStatus,SecurityServicesRunning,SecurityServicesConfigured | Format-List | Out-String))
        SessionSvc = ((Get-Service vmicvmsession -ErrorAction SilentlyContinue | Select-Object Status,StartType | Format-List | Out-String))
        RDP = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    }
}
$r | Format-List | Out-String | ForEach-Object { L $_ }
Remove-PSSession $s -ErrorAction SilentlyContinue
Set-Content 'C:\VMs\iso-rebuild\win11-config-probe-done.txt' (Get-Date -Format o) -Encoding UTF8
