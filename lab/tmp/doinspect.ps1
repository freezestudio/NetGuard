$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\lab\tmp\inspect.ps1" -ToSession $s -Destination 'C:\NetGuard\inspect.ps1' -Force
Copy-Item "$RepoRoot\lab\tmp\inspect.cmd" -ToSession $s -Destination 'C:\NetGuard\inspect.cmd' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\inspect.out' -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NG-Insp /f 2>&1 | Out-Null
  & schtasks.exe /create /tn NG-Insp /tr 'C:\NetGuard\inspect.cmd' /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NG-Insp 2>&1 | Out-Null
  Start-Sleep 20
  & schtasks.exe /delete /tn NG-Insp /f 2>&1 | Out-Null
  Get-Content 'C:\NetGuard\inspect.out' -ErrorAction SilentlyContinue | Select-Object -First 40
}
Remove-PSSession $s
