$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
    '--- DriverTest reg ---'
    Get-ItemProperty 'HKLM:\SOFTWARE\NetGuard\DriverTest' -ErrorAction SilentlyContinue | Format-List
    '--- services ---'
    & sc.exe query ngdrv 2>&1
    '--- system event 7000/7001/7024/7045 ---'
    Get-WinEvent -FilterHashtable @{LogName='System'; Id=7000,7001,7024,7045} -MaxEvents 10 -ErrorAction SilentlyContinue |
      Select-Object TimeCreated,Id,ProviderName,Message | Format-List
}
Remove-PSSession $s
