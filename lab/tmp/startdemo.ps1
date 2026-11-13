$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item "$RepoRoot\lab\tmp\demo.ps1" -ToSession $s -Destination 'C:\NetGuard\demo.ps1' -Force
if (-not (Test-Path "$RepoRoot\lab\admin.dat")) { throw 'admin.dat missing' }
Copy-Item "$RepoRoot\lab\admin.dat" -ToSession $s -Destination 'C:\ProgramData\NetGuard\admin.dat' -Force
Invoke-Command -Session $s -ScriptBlock {
  # 清掉上次失败留下的窗口与任务
  Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 1 } | Stop-Process -Force
  & schtasks.exe /delete /tn NG-Demo /f 2>&1 | Out-Null
  Remove-Item 'C:\NetGuard\demo-shots' -Recurse -Force -ErrorAction SilentlyContinue
  & icacls 'C:\ProgramData\NetGuard\admin.dat' /inheritance:r | Out-Null
  & icacls 'C:\ProgramData\NetGuard\admin.dat' /grant '*S-1-5-18:F' | Out-Null
  & icacls 'C:\ProgramData\NetGuard\admin.dat' /grant '*S-1-5-32-544:F' | Out-Null
  'admin.dat=' + (Test-Path 'C:\ProgramData\NetGuard\admin.dat')
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File C:\NetGuard\demo.ps1'
  (& schtasks.exe /create /tn NG-Demo /tr $tr /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-String).Trim()
  (& schtasks.exe /run /tn NG-Demo 2>&1 | Out-String).Trim()
  Start-Sleep 6
  'running pids(session1)=' + ((Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 1 } | ForEach-Object Id) -join ',')
  'shots dir=' + (Test-Path 'C:\NetGuard\demo-shots')
  if (Test-Path 'C:\NetGuard\demo-shots\steps.txt') { Get-Content 'C:\NetGuard\demo-shots\steps.txt' -Encoding ascii }
}
Remove-PSSession $s
