$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$log="$RepoRoot\lab\diag-win10-2.log"
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== diag2 $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8
$cred=New-Object System.Management.Automation.PSCredential('freeze',(ConvertTo-SecureString '1' -AsPlainText -Force))
$s=New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred -ErrorAction Stop
$r=Invoke-Command -Session $s -ScriptBlock {
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 0 } | Stop-Process -Force
    $o=@()
    $o += '--- app errors with time ---'
    $o += (Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'; StartTime=(Get-Date).AddHours(-3)} -ErrorAction SilentlyContinue | Select-Object TimeCreated,Id,Message | Format-List | Out-String)
    $o += '--- service state ---'
    $o += (Get-Service NetGuard | Select-Object Status,StartType | Format-List | Out-String)
    $o += (Get-Process NetGuard -ErrorAction SilentlyContinue | Select-Object Id,StartTime,SessionId | Format-Table -Auto | Out-String)
    $o += '--- winlogon auto logon ---'
    $wl='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $o += (Get-ItemProperty $wl | Select-Object AutoAdminLogon,DefaultUserName,DefaultPassword,DefaultDomainName,ForceAutoLogon | Format-List | Out-String)
    $o += '--- computer name ---'
    $o += $env:COMPUTERNAME
    $o += '--- policy signature ---'
    $o += (& cmd.exe /c 'C:\NetGuard\NetGuard.exe verify' 2>&1) -join "`n"
    $o
}
$r | ForEach-Object { L "$_" }
Remove-PSSession $s
'DONE' | Out-File $log -Append -Encoding utf8
