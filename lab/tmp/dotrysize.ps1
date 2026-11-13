$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\lab\tmp\trysize.ps1" -ToSession $s -Destination 'C:\NetGuard\trysize.ps1' -Force
Copy-Item "$RepoRoot\lab\tmp\trysize.cmd" -ToSession $s -Destination 'C:\NetGuard\trysize.cmd' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\size-*.png','C:\NetGuard\trysize.out' -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NG-Sz /f 2>&1 | Out-Null
  & schtasks.exe /create /tn NG-Sz /tr 'C:\NetGuard\trysize.cmd' /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NG-Sz 2>&1 | Out-Null
  Start-Sleep 20
  & schtasks.exe /delete /tn NG-Sz /f 2>&1 | Out-Null
  Get-Content 'C:\NetGuard\trysize.out' -ErrorAction SilentlyContinue
}
foreach ($n in @('size-before','size-1100x640','size-1250x700','size-1000x600')) {
  try { Copy-Item -FromSession $s -Path "C:\NetGuard\$n.png" -Destination "$RepoRoot\lab\shots\$n.png" -Force; "${n}: " + (Get-Item "$RepoRoot\lab\shots\$n.png").Length } catch { "$n missing" }
}
Remove-PSSession $s
