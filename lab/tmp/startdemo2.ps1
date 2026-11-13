$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*demo.ps1*' } | ForEach-Object { "kill $($_.ProcessId) sess=$($_.SessionId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NG-Demo /f 2>&1 | Out-Null
  Remove-Item 'C:\NetGuard\demo-shots' -Recurse -Force -ErrorAction SilentlyContinue
  Start-Sleep 2
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File C:\NetGuard\demo.ps1'
  & schtasks.exe /create /tn NG-Demo /tr $tr /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NG-Demo 2>&1 | Out-Null
  Start-Sleep 20
  'steps:'
  if (Test-Path 'C:\NetGuard\demo-shots\steps.txt') { Get-Content 'C:\NetGuard\demo-shots\steps.txt' -Encoding ascii } else { 'none yet' }
  'pngs:'
  if (Test-Path 'C:\NetGuard\demo-shots') { Get-ChildItem 'C:\NetGuard\demo-shots\*.png' | Select Name,Length | Format-Table -Auto | Out-String }
}
Remove-PSSession $s
