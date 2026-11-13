$ErrorActionPreference = 'Continue'
$log = 'C:\NetGuard\latest.log'
"=== NetGuard latest build test $(Get-Date -Format o) ===" | Set-Content $log -Encoding UTF8
function L($m) { Add-Content -Path $log -Value $m -Encoding UTF8 }

function Run($title, $file, [string[]]$argList) {
    L ""
    L "--- $title ---"
    $out = 'C:\NetGuard\_o.txt'
    Remove-Item $out, "$out.err" -Force -ErrorAction SilentlyContinue
    try {
        $p = Start-Process -FilePath $file -ArgumentList $argList -NoNewWindow -Wait -PassThru `
             -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        L "exit=$($p.ExitCode)"
    } catch {
        L "launch failed: $($_.Exception.Message)"
    }
    if (Test-Path $out) { Get-Content $out -Encoding Default | ForEach-Object { L "  $_" } }
    if (Test-Path "$out.err") { Get-Content "$out.err" -Encoding Default | ForEach-Object { L "  ERR $_" } }
}

L "whoami: $(& cmd.exe /c whoami 2>&1)"
L "OS: $((Get-WmiObject Win32_OperatingSystem).Caption) / $((Get-WmiObject Win32_OperatingSystem).Version)"

$ng = 'C:\NetGuard\NetGuard.exe'
Run '1. initpolicy' $ng @('initpolicy')
Run '2. initkey' $ng @('initkey')
Run '3. trial (expect 60 days)' $ng @('trial')
Run '4. verify' $ng @('verify')
Run '5. end-to-end test (baseline/apply/rollback)' $ng @('test')

Run '6. install service' 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\NetGuard\install-netguard.ps1')
Run '7. sc query' 'cmd.exe' @('/c', 'sc query NetGuard')
Run '8. status' $ng @('status')
Run '9. ctl status' $ng @('ctl', 'status')
Run '10. ping 8.8.8.8 (expect blocked)' 'cmd.exe' @('/c', 'ping -n 2 8.8.8.8')

Run '11. ctl temp 1' $ng @('ctl', 'temp', '1')
Run '12. ctl status while temp' $ng @('ctl', 'status')
L "waiting 85s for watchdog to restore..."
Start-Sleep -Seconds 85
Run '13. ctl status restored' $ng @('ctl', 'status')

Run '14. uninstall service' 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\NetGuard\uninstall-netguard.ps1')
Run '15. sc query after uninstall' 'cmd.exe' @('/c', 'sc query NetGuard')
Run '16. trial after uninstall' $ng @('trial')
Run '17. selftest after uninstall (baseline, exit 2 = reachable)' $ng @('selftest')

L ""
L "=== data files ==="
Get-ChildItem 'C:\ProgramData\NetGuard' -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name) $($_.Length)" }
if (Test-Path 'C:\ProgramData\NetGuard\filters.txt') {
    L "filters.txt lines=$((Get-Content 'C:\ProgramData\NetGuard\filters.txt').Count)"
}
L "DONE"
