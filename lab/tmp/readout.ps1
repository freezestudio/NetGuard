$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
  '--- arrange.out ---'
  Get-Content 'C:\NetGuard\arrange.out' -ErrorAction SilentlyContinue
  '--- exists? ---'
  'png=' + (Test-Path 'C:\NetGuard\arrange.png')
}
Remove-PSSession $s
