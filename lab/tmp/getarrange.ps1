$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Copy-Item -FromSession $s -Path 'C:\NetGuard\arrange.png' -Destination 'C:\src\NetGuard\lab\shots\arrange.png' -Force
Remove-PSSession $s
