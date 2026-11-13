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
  $junk = @('snap.ps1','snap.cmd','arrange.ps1','arrange.cmd','winfo.ps1','winfo.cmd','trysize.ps1','trysize.cmd',
            'res.ps1','res.cmd','final.ps1','final.cmd','shot.ps1','shot.cmd','inspect.ps1','inspect.cmd',
            'showcase.ps1','showcase.cmd','ui-client.png','ui-window.png','ui-screen.png','size-before.png',
            'size-1100x640.png','size-1250x700.png','size-1000x600.png','showcase.png','arrange.png','final-screen.png',
            'snap.png','shot-test.png','shot-test.txt','demo-test.out','demo-test.err','inspect.out','winfo.out',
            'trysize.out','res.out','final.out','showcase.out','arrange.out')
  foreach ($f in $junk) { Remove-Item (Join-Path 'C:\NetGuard' $f) -Force -ErrorAction SilentlyContinue }
  Get-ChildItem 'C:\NetGuard' | Select-Object Name,Length | Format-Table -Auto | Out-String
  'demo-shots: ' + ((Get-ChildItem 'C:\NetGuard\demo-shots' -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')
  'admin.dat=' + (Test-Path 'C:\ProgramData\NetGuard\admin.dat')
}
Remove-PSSession $s
