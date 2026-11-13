$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
  '--- task ---'
  (& schtasks.exe /query /tn NG-Demo /v /fo list 2>&1) -join "`n"
  '--- demo-shots ---'
  if (Test-Path 'C:\NetGuard\demo-shots') { Get-ChildItem 'C:\NetGuard\demo-shots' | Select-Object Name,Length,LastWriteTime | Format-Table -Auto | Out-String } else { 'no folder' }
  '--- steps.txt ---'
  if (Test-Path 'C:\NetGuard\demo-shots\steps.txt') { Get-Content 'C:\NetGuard\demo-shots\steps.txt' -Encoding ascii } else { 'none' }
  '--- processes ---'
  Get-Process powershell,NetGuardUI,NetGuard,cmd -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,SessionId,StartTime | Format-Table -Auto | Out-String
  '--- service ---'
  'svc=' + (Get-Service NetGuard).Status
  '--- demo.ps1 present ---'
  if (Test-Path 'C:\NetGuard\demo.ps1') { (Get-Item 'C:\NetGuard\demo.ps1').Length } else { 'missing' }
}
Remove-PSSession $s
