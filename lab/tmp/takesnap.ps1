$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\lab\tmp\snap.ps1" -ToSession $s -Destination 'C:\NetGuard\snap.ps1' -Force
Copy-Item "$RepoRoot\lab\tmp\snap.cmd" -ToSession $s -Destination 'C:\NetGuard\snap.cmd' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\snap.png' -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NGShot3 /f 2>&1 | Out-Null
  & schtasks.exe /create /tn NGShot3 /tr 'C:\NetGuard\snap.cmd' /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NGShot3 2>&1 | Out-Null
  Start-Sleep 8
  & schtasks.exe /delete /tn NGShot3 /f 2>&1 | Out-Null
  if (Test-Path 'C:\NetGuard\snap.png') { 'size=' + (Get-Item 'C:\NetGuard\snap.png').Length } else { 'NO SNAP' }
}
Copy-Item -FromSession $s -Path 'C:\NetGuard\snap.png' -Destination "$RepoRoot\lab\shots\snap.png" -Force -ErrorAction SilentlyContinue
Remove-PSSession $s
