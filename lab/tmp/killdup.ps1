$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*demo.ps1*' -and $_.SessionId -eq 0 } |
    ForEach-Object { "kill pid=$($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Get-Process NetGuardUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
  'session1 powershell=' + ((Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.SessionId -eq 1 } | ForEach-Object ProcessId) -join ',')
  if (Test-Path 'C:\NetGuard\demo-shots\steps.txt') { Get-Content 'C:\NetGuard\demo-shots\steps.txt' -Encoding ascii }
}
Remove-PSSession $s
