$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item 'C:\src\NetGuard\lab\tmp\shot_guest.ps1' -ToSession $s -Destination 'C:\NetGuard\shot.ps1' -Force
Copy-Item 'C:\src\NetGuard\lab\tmp\shot.cmd' -ToSession $s -Destination 'C:\NetGuard\shot.cmd' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\shot-test.png','C:\NetGuard\shot-test.txt' -ErrorAction SilentlyContinue
  $tr = 'C:\NetGuard\shot.cmd'
  & schtasks.exe /create /tn NGShot2 /tr $tr /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NGShot2 2>&1 | Out-Null
  Start-Sleep 12
  if (Test-Path 'C:\NetGuard\shot-test.png') { 'png size=' + (Get-Item 'C:\NetGuard\shot-test.png').Length; Get-Content 'C:\NetGuard\shot-test.txt' } else { 'NO PNG'; (Get-Content 'C:\NetGuard\shot-test.txt' -ErrorAction SilentlyContinue) }
  & schtasks.exe /delete /tn NGShot2 /f 2>&1 | Out-Null
}
Copy-Item -FromSession $s -Path 'C:\NetGuard\shot-test.png' -Destination 'C:\src\NetGuard\lab\shots\shot-test.png' -Force -ErrorAction SilentlyContinue
Remove-PSSession $s
