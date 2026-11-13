$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
$names = @('01-desktop','02-status','03-blocked','04-rollback','05-reapplied','06-selftest','07-temp','08-temp-restored','09-ui','10-ui-final')
foreach ($n in $names) {
  try {
    Copy-Item -FromSession $s -Path "C:\NetGuard\demo-shots\$n.png" -Destination "$RepoRoot\lab\shots\$n.png" -Force -ErrorAction Stop
    Write-Host ("{0}.png {1:N0}" -f $n, (Get-Item "$RepoRoot\lab\shots\$n.png").Length)
  } catch { Write-Host "$n missing" }
}
Invoke-Command -Session $s -ScriptBlock { Get-ChildItem 'C:\NetGuard\demo-shots\*.png' | Select Name,Length,LastWriteTime | Format-Table -Auto | Out-String }
Remove-PSSession $s
