$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\lab\tmp\final.ps1" -ToSession $s -Destination 'C:\NetGuard\final.ps1' -Force
Copy-Item "$RepoRoot\lab\tmp\final.cmd" -ToSession $s -Destination 'C:\NetGuard\final.cmd' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\final-screen.png','C:\NetGuard\final.out' -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NG-Fin /f 2>&1 | Out-Null
  & schtasks.exe /create /tn NG-Fin /tr 'C:\NetGuard\final.cmd' /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NG-Fin 2>&1 | Out-Null
  Start-Sleep 22
  & schtasks.exe /delete /tn NG-Fin /f 2>&1 | Out-Null
  Get-Content 'C:\NetGuard\final.out' -ErrorAction SilentlyContinue
}
Copy-Item -FromSession $s -Path 'C:\NetGuard\final-screen.png' -Destination "$RepoRoot\lab\shots\final-screen.png" -Force -ErrorAction SilentlyContinue
Remove-PSSession $s
