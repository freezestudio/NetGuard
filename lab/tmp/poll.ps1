$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
  if (Test-Path 'C:\NetGuard\demo-shots\steps.txt') { Get-Content 'C:\NetGuard\demo-shots\steps.txt' -Encoding ascii }
  Get-ChildItem 'C:\NetGuard\demo-shots\*.png' -ErrorAction SilentlyContinue | Select Name,Length,LastWriteTime | Format-Table -Auto | Out-String
  'session1 windows:'
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 1 -and $_.MainWindowTitle } | Select ProcessName,MainWindowTitle | Format-Table -Auto | Out-String
}
Remove-PSSession $s
