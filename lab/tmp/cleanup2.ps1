$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
  $o='C:\ProgramData\NetGuard\st.out'
  $p=Start-Process 'C:\NetGuard\NetGuard.exe' -ArgumentList 'ctl status' -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o
  'ctl status:'
  Get-Content $o -Encoding Default
  Remove-Item $o -Force
  'svc=' + (Get-Service NetGuard).Status
  # 清理一次性辅助脚本，只保留部署件与演示脚本
  Remove-Item 'C:\NetGuard\snap.ps1','C:\NetGuard\snap.cmd','C:\NetGuard\arrange.ps1','C:\NetGuard\arrange.cmd',
              'C:\NetGuard\winfo.ps1','C:\NetGuard\winfo.cmd','C:\NetGuard\trysize.ps1','C:\NetGuard\trysize.cmd',
              'C:\NetGuard\res.ps1','C:\NetGuard\res.cmd','C:\NetGuard\final.ps1','C:\NetGuard\final.cmd',
              'C:\NetGuard\shot.ps1','C:\NetGuard\shot.cmd','C:\NetGuard\inspect.ps1','C:\NetGuard\inspect.cmd',
              'C:\NetGuard\showcase.ps1','C:\NetGuard\showcase.cmd' -Force -ErrorAction SilentlyContinue
  Get-ChildItem 'C:\NetGuard' | Select-Object Name,Length | Format-Table -Auto | Out-String
  'demo-shots: ' + ((Get-ChildItem 'C:\NetGuard\demo-shots' -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')
  'ProgramData admin.dat=' + (Test-Path 'C:\ProgramData\NetGuard\admin.dat')
}
Remove-PSSession $s
