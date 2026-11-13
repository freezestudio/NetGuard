$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item 'C:\src\NetGuard\lab\tmp\arrange.ps1' -ToSession $s -Destination 'C:\NetGuard\arrange.ps1' -Force
Copy-Item 'C:\src\NetGuard\lab\tmp\arrange.cmd' -ToSession $s -Destination 'C:\NetGuard\arrange.cmd' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\arrange.png','C:\NetGuard\arrange.out' -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NG-Arrange /f 2>&1 | Out-Null
  & schtasks.exe /create /tn NG-Arrange /tr 'C:\NetGuard\arrange.cmd' /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NG-Arrange 2>&1 | Out-Null
  Start-Sleep 16
  & schtasks.exe /delete /tn NG-Arrange /f 2>&1 | Out-Null
  Get-Content 'C:\NetGuard\arrange.out' -ErrorAction SilentlyContinue
  if (Test-Path 'C:\NetGuard\arrange.png') { 'png=' + (Get-Item 'C:\NetGuard\arrange.png').Length } else { 'no png' }
}
Copy-Item -FromSession $s -Path 'C:\NetGuard\arrange.png' -Destination 'C:\src\NetGuard\lab\shots\arrange.png' -Force -ErrorAction SilentlyContinue
Remove-PSSession $s
