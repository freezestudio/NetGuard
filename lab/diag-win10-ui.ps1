$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$log="$RepoRoot\lab\diag-win10-ui.log"
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== diag $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8
$cred=New-Object System.Management.Automation.PSCredential('freeze',(ConvertTo-SecureString '1' -AsPlainText -Force))
$s=New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred -ErrorAction Stop
$r=Invoke-Command -Session $s -ScriptBlock {
    $o=@()
    $o += '--- quser ---'
    $o += (& query.exe user 2>&1)
    $o += '--- processes ---'
    $o += (Get-Process NetGuard*,NGUI* -ErrorAction SilentlyContinue | Select-Object Id,Name,SessionId,MainWindowHandle | Format-Table -Auto | Out-String)
    $o += '--- admin.dat ---'
    $o += "exists=" + (Test-Path 'C:\ProgramData\NetGuard\admin.dat')
    $o += '--- task ---'
    $o += (Get-ScheduledTask -TaskName 'NgUiTest' -ErrorAction SilentlyContinue | Select-Object TaskName,State | Format-Table -Auto | Out-String)
    $o += '--- try launch UI as current PS Direct (session 0) ---'
    $p = Start-Process -FilePath 'C:\NetGuard\NetGuardUI.exe' -PassThru -ErrorAction SilentlyContinue
    Start-Sleep 3
    if ($p) { $o += "pid=$($p.Id) hasExited=$($p.HasExited) exit=$($p.ExitCode)" } else { $o += 'start failed' }
    $o += (Get-Process NetGuardUI -ErrorAction SilentlyContinue | Select-Object Id,SessionId,MainWindowHandle | Format-Table -Auto | Out-String)
    $o += '--- event log errors ---'
    $o += (Get-EventLog -LogName Application -EntryType Error -Newest 6 -ErrorAction SilentlyContinue | Select-Object TimeGenerated,EventID,Source | Format-Table -Auto | Out-String)
    $o += (Get-EventLog -LogName Application -Source 'Application Error' -Newest 3 -ErrorAction SilentlyContinue | ForEach-Object { $_.Message })
    $o
}
$r | ForEach-Object { L "$_" }
Get-Process NetGuardUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 0 } | Stop-Process -Force
Remove-PSSession $s
'DONE' | Out-File $log -Append -Encoding utf8
