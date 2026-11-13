$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
  Get-Content 'C:\NetGuard\winfo.out' -ErrorAction SilentlyContinue
  Get-ChildItem 'C:\NetGuard\ui-*.png' -ErrorAction SilentlyContinue | Select Name,Length | Format-Table -Auto | Out-String
}
Remove-PSSession $s
