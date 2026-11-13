$ErrorActionPreference = 'Continue'
$log = 'C:\VMs\iso-rebuild\win11-testsigning.log'
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== Win11 enable testsigning ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
$name = 'Win11-Test'
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
function Connect-Guest {
    for ($i=0; $i -lt 30; $i++) {
        try { return New-PSSession -VMName $name -Credential $cred -ErrorAction Stop } catch { Start-Sleep 5 }
    }
    return $null
}

# Secure Boot off (vTPM template locked, but toggling should work)
try {
    Set-VMFirmware -VMName $name -EnableSecureBoot Off -ErrorAction Stop
    L ('SecureBoot=' + (Get-VMFirmware -VMName $name).SecureBoot)
} catch {
    L ('secureboot off while running failed: ' + $_.Exception.Message)
    Stop-VM -Name $name -TurnOff -Force; Start-Sleep 4
    Set-VMFirmware -VMName $name -EnableSecureBoot Off
    Start-VM -Name $name; Start-Sleep 10
    L ('SecureBoot=' + (Get-VMFirmware -VMName $name).SecureBoot)
}

$s = Connect-Guest
if (-not $s) { L 'PS Direct failed before testsigning'; exit 1 }
$r = Invoke-Command -Session $s -ScriptBlock {
    $o1 = & bcdedit.exe /set testsigning on 2>&1
    $o2 = & bcdedit.exe /set nointegritychecks on 2>&1
    [pscustomobject]@{ B1 = ($o1 -join "`n"); B2 = ($o2 -join "`n") }
}
L ('bcdedit testsigning: ' + $r.B1)
L ('bcdedit nointegrity: ' + $r.B2)
Invoke-Command -Session $s -ScriptBlock { shutdown.exe /r /t 2 /f } -ErrorAction SilentlyContinue
Remove-PSSession $s -ErrorAction SilentlyContinue
L 'rebooting guest'

Start-Sleep 60
$s = Connect-Guest
if (-not $s) { L 'PS Direct failed after reboot'; exit 1 }
$r = Invoke-Command -Session $s -ScriptBlock {
    $o = (& bcdedit.exe /enum '{current}' 2>&1) -join "`n"
    $dg = (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard | Select-Object VirtualizationBasedSecurityStatus,SecurityServicesRunning | Format-List | Out-String)
    [pscustomobject]@{ Bcd = $o; DG = $dg }
}
L ('after reboot testsigning line: ' + (($r.Bcd -split "`r?`n" | Where-Object { $_ -match 'testsigning|nointegrity' }) -join ' | '))
L ('DeviceGuard: ' + (($r.DG -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | '))
Remove-PSSession $s -ErrorAction SilentlyContinue
Set-Content 'C:\VMs\iso-rebuild\win11-testsigning-done.txt' (Get-Date -Format o) -Encoding UTF8
