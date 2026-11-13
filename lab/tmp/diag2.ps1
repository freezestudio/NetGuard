$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
  '--- session1 processes with windows ---'
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 1 } |
    Select-Object Id,ProcessName,MainWindowTitle | Format-Table -Auto | Out-String
  '--- demo-shots now ---'
  Test-Path 'C:\NetGuard\demo-shots'
  if (Test-Path 'C:\NetGuard\demo-shots') { Get-ChildItem 'C:\NetGuard\demo-shots' | Select Name,Length | Format-Table -Auto | Out-String }
  '--- task last result ---'
  (& schtasks.exe /query /tn NG-Demo /fo list 2>&1) -join "`n"
  '--- event log for task ---'
  try { Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational'; StartTime=(Get-Date).AddMinutes(-15)} -MaxEvents 20 -ErrorAction Stop | Select TimeCreated,Id,Message | Format-Table -Wrap | Out-String } catch { 'eventlog: ' + $_.Exception.Message }
  '--- try running demo.ps1 directly (capture output) ---'
  $o='C:\NetGuard\demo-test.out'; $e='C:\NetGuard\demo-test.err'
  $p=Start-Process 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\NetGuard\demo.ps1' -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
  'exit=' + $p.ExitCode
  '--- stdout ---'; Get-Content $o -Encoding Default
  '--- stderr ---'; Get-Content $e -Encoding Default
}
Remove-PSSession $s
