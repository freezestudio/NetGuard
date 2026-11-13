$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\lab\tmp\res.ps1" -ToSession $s -Destination 'C:\NetGuard\res.ps1' -Force
Copy-Item "$RepoRoot\lab\tmp\res.cmd" -ToSession $s -Destination 'C:\NetGuard\res.cmd' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\res.out' -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NG-Res /f 2>&1 | Out-Null
  & schtasks.exe /create /tn NG-Res /tr 'C:\NetGuard\res.cmd' /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NG-Res 2>&1 | Out-Null
  Start-Sleep 15
  & schtasks.exe /delete /tn NG-Res /f 2>&1 | Out-Null
  Get-Content 'C:\NetGuard\res.out' -ErrorAction SilentlyContinue
}
Remove-PSSession $s
