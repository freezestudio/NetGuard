$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\lab\tmp\showcase.ps1" -ToSession $s -Destination 'C:\NetGuard\showcase.ps1' -Force
Copy-Item "$RepoRoot\lab\tmp\showcase.cmd" -ToSession $s -Destination 'C:\NetGuard\showcase.cmd' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\showcase.png','C:\NetGuard\showcase.out' -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NG-Show /f 2>&1 | Out-Null
  & schtasks.exe /create /tn NG-Show /tr 'C:\NetGuard\showcase.cmd' /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NG-Show 2>&1 | Out-Null
  Start-Sleep 25
  & schtasks.exe /delete /tn NG-Show /f 2>&1 | Out-Null
  Get-Content 'C:\NetGuard\showcase.out' -ErrorAction SilentlyContinue
  if (Test-Path 'C:\NetGuard\showcase.png') { 'png=' + (Get-Item 'C:\NetGuard\showcase.png').Length }
}
Copy-Item -FromSession $s -Path 'C:\NetGuard\showcase.png' -Destination "$RepoRoot\lab\shots\showcase.png" -Force -ErrorAction SilentlyContinue
Remove-PSSession $s
