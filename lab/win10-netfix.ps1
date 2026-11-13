$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win10-netfix.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win10 NAT fix + retest $(Get-Date -Format o) ===" | Set-Content $log -Encoding utf8

try { Restart-Service SharedAccess -Force -ErrorAction Stop; L "SharedAccess restarted"; Start-Sleep 6 }
catch { L "SharedAccess restart failed: $($_.Exception.Message)" }

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = $null
for ($i = 0; $i -lt 12; $i++) {
    try { $s = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop; break }
    catch { Start-Sleep 5 }
}
if (-not $s) { L "PS Direct failed"; exit 1 }
L "PS Direct ready"

Invoke-Command -Session $s -ScriptBlock {
    & ipconfig /release * | Out-Null
    Start-Sleep 2
    & ipconfig /renew | Out-Null
    Start-Sleep 6
    '--- ipconfig after renew ---'
    & ipconfig
    '--- tcp test ---'
    $r = Test-NetConnection -ComputerName 8.8.8.8 -Port 53 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    "TcpTestSucceeded=$($r.TcpTestSucceeded)"
} | ForEach-Object { L "  $_" }

# 服务已卸载；现在跑端到端 test（基线应能连出、应用后拦截、回滚后恢复）
try {
    Invoke-Command -Session $s -ScriptBlock {
        $out = 'C:\NetGuard\netfix-test.txt'
        Remove-Item $out -Force -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath 'C:\NetGuard\NetGuard.exe' -ArgumentList 'test' -NoNewWindow -Wait -PassThru `
             -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        "test exit=$($p.ExitCode)"
        if (Test-Path $out) { Get-Content $out -Encoding Default }
        if (Test-Path "$out.err") { Get-Content "$out.err" -Encoding Default }
    } | ForEach-Object { L "  $_" }
} catch { L "test failed: $($_.Exception.Message)" }

try {
    Copy-Item -FromSession $s 'C:\NetGuard\netfix-test.txt' "$RepoRoot\lab\win10-netfix-test.txt" -Force
} catch { L "copy test output failed" }

Remove-PSSession $s
L "DONE (VM left running)"
