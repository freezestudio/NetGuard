$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\lab\tmp\winfo.ps1" -ToSession $s -Destination 'C:\NetGuard\winfo.ps1' -Force
Invoke-Command -Session $s -ScriptBlock {
  Remove-Item 'C:\NetGuard\ui-*.png','C:\NetGuard\winfo.out' -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NG-Info /f 2>&1 | Out-Null
  & schtasks.exe /create /tn NG-Info /tr 'C:\NetGuard\winfo.cmd' /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NG-Info 2>&1 | Out-Null
  Start-Sleep 25
  & schtasks.exe /delete /tn NG-Info /f 2>&1 | Out-Null
  Get-Content 'C:\NetGuard\winfo.out' -ErrorAction SilentlyContinue
  Get-ChildItem 'C:\NetGuard\ui-*.png' -ErrorAction SilentlyContinue | Select Name,Length | Format-Table -Auto | Out-String
}
foreach ($n in @('ui-client','ui-screen')) {
  try { Copy-Item -FromSession $s -Path "C:\NetGuard\$n.png" -Destination "$RepoRoot\lab\shots\$n.png" -Force -ErrorAction Stop; "${n}: " + (Get-Item "$RepoRoot\lab\shots\$n.png").Length } catch { "$n missing" }
}
Remove-PSSession $s
