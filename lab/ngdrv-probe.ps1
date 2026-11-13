$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    'admin=' + $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    & whoami.exe /groups | Select-String -Pattern 'S-1-5-32-544','S-1-16-12288','S-1-16-8192'
    & certutil.exe -addstore -f Root C:\NetGuard\drv\NetGuardTest.cer 2>&1
    'certutil_exit=' + $LASTEXITCODE
    & certutil.exe -addstore -f TrustedPublisher C:\NetGuard\drv\NetGuardTest.cer 2>&1
    'tp_exit=' + $LASTEXITCODE
}
Remove-PSSession $s
