$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win10-reboot-net.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win10 reboot + network retest $(Get-Date -Format o) ===" | Set-Content $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
Restart-VM -Name $vmName -Force
L "VM restarted"
Start-Sleep 20

$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = $null
for ($i = 0; $i -lt 40; $i++) {
    try { $s = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop; break }
    catch { Start-Sleep 5 }
}
if (-not $s) { L "PS Direct failed after reboot"; exit 1 }
L "PS Direct ready"

Invoke-Command -Session $s -ScriptBlock {
    Start-Sleep 5
    '--- ipconfig ---'
    & ipconfig
    '--- tcp test ---'
    $r = Test-NetConnection -ComputerName 8.8.8.8 -Port 53 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    "TcpTestSucceeded=$($r.TcpTestSucceeded)"
    '--- netguard presence ---'
    & sc.exe query NetGuard
    Get-Process NetGuard -ErrorAction SilentlyContinue | Select-Object Id, ProcessName
    if (Test-Path 'C:\ProgramData\NetGuard\filters.txt') { 'filters.txt lines=' + (Get-Content 'C:\ProgramData\NetGuard\filters.txt').Count }
    '--- end-to-end test (no service) ---'
    $out = 'C:\NetGuard\reboot-test.txt'
    Remove-Item $out -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath 'C:\NetGuard\NetGuard.exe' -ArgumentList 'test' -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    "test exit=$($p.ExitCode)"
    if (Test-Path $out) { Get-Content $out -Encoding Default }
} | ForEach-Object { L "  $_" }

try { Copy-Item -FromSession $s 'C:\NetGuard\reboot-test.txt' "$RepoRoot\lab\win10-reboot-test.txt" -Force } catch { }
Remove-PSSession $s
L "DONE (VM left running)"
