$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$log = "$RepoRoot\lab\win11-enforcement.log"
$done = "$RepoRoot\lab\win11-enforcement-done.txt"
$exe = 'C:\NetGuard\NetGuard.exe'
$data = 'C:\ProgramData\NetGuard'
$policy = Join-Path $data 'policy.ini'
$rbScript = 'C:\NetGuard\auto-rollback.ps1'
$rbProc = $null
$applied = $false

function L([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
function Relax-Policy {
    $relax = @"
[general]
DefaultDeny=0
AllowDhcp=1
AllowLoopback=1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=placeholder
Cidr=10.10.10.10/32
Ports=8000
Proto=TCP
Enable=1
"@
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    [IO.File]::WriteAllText($policy, ($relax -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path $exe) { & $exe sign | Out-Null }
}
function Stop-NetGuard {
    try { if (Test-Path $exe) { & $exe ctl rollback | Out-Null } } catch { }
    try { & "$env:SystemRoot\System32\sc.exe" stop NetGuard | Out-Null } catch { }
}

Remove-Item $done -Force -ErrorAction SilentlyContinue
'=== Win11 enforcement test ' + (Get-Date -Format o) + ' ===' | Set-Content -Path $log -Encoding UTF8

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    L ('user=' + $id.Name + ' admin=' + $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

    # 1) 清理旧服务/过滤器
    L '--- cleanup old service/filters ---'
    $svc = Get-Service NetGuard -ErrorAction SilentlyContinue
    if ($svc) {
        & "$env:SystemRoot\System32\sc.exe" stop NetGuard | Out-Null
        Start-Sleep 3
        & "$env:SystemRoot\System32\sc.exe" delete NetGuard | Out-Null
        Start-Sleep 2
    }
    New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    Copy-Item "$RepoRoot\build\NetGuard.exe" $exe -Force
    Copy-Item "$RepoRoot\build\NetGuardUI.exe" 'C:\NetGuard\NetGuardUI.exe' -Force
    & $exe purge | Out-Null

    # 2) 部署密钥 + 策略
    L '--- initkey ---'
    & $exe initkey | ForEach-Object { L ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) { throw 'initkey failed' }

    $hPkg = (& $exe hash 'C:\Users\freez\AppData\Local\vite-plus\data\packages\@opencode\cli\1b817570-f92c-4261-934e-ff6978f9aff6\node_modules\@opencode\cli\bin\opencode.exe').Trim()
    $hBin = (& $exe hash 'C:\Users\freez\AppData\Local\vite-plus\bin\opencode.exe').Trim()
    L ('opencode hashes: pkg=' + $hPkg + ' bin=' + $hBin)

    $pol = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
AllowDnsServer=192.168.1.1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=AnyV4
Cidr=0.0.0.0/0
Ports=0-65535
Proto=ANY
Enable=1

[ep.2]
Name=AnyV6
Cidr=::/0
Ports=0-65535
Proto=ANY
Enable=1

[proc.1]
Name=opencode-pkg
Path=C:\Users\freez\AppData\Local\vite-plus\data\packages\@opencode\cli\1b817570-f92c-4261-934e-ff6978f9aff6\node_modules\@opencode\cli\bin\opencode.exe
Sha256=$hPkg
Endpoint=AnyV4,AnyV6
Enable=1

[proc.2]
Name=opencode-bin
Path=C:\Users\freez\AppData\Local\vite-plus\bin\opencode.exe
Sha256=$hBin
Endpoint=AnyV4,AnyV6
Enable=1
"@
    [IO.File]::WriteAllText($policy, ($pol -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
    L '--- sign ---'
    & $exe sign | ForEach-Object { L ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) { throw 'sign failed' }

    # 3) 先布好自动回滚，再启动服务
    $rb = @'
Start-Sleep 90
& 'C:\NetGuard\NetGuard.exe' ctl rollback
& sc.exe stop NetGuard
'@
    [IO.File]::WriteAllText($rbScript, ($rb -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
    $rbProc = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$rbScript) -WindowStyle Hidden -PassThru
    L ('auto-rollback started pid=' + $rbProc.Id + ' (90s)')

    L '--- install/start service ---'
    & $exe install | ForEach-Object { L ('  ' + $_) }
    & "$env:SystemRoot\System32\sc.exe" start NetGuard | Out-Null
    $applied = $true

    $st = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep 2
        $st = (& $exe ctl status 2>&1) -join "`n"
        if ($st -match 'filters=') { break }
    }
    L '--- status after service start ---'
    ($st -split "`r?`n") | ForEach-Object { L ('  ' + $_) }
    if ($st -notmatch 'filters=') { throw 'service IPC not ready' }

    L '--- ctl apply ---'
    $ap = (& $exe ctl apply 2>&1) -join "`n"
    L ('  ' + $ap)
    $st = (& $exe ctl status 2>&1) -join "`n"
    L '--- status after apply ---'
    ($st -split "`r?`n") | ForEach-Object { L ('  ' + $_) }

    # 4) 实测：非白名单进程必须被拦截
    L '--- tests: non-whitelisted processes ---'
    $t0 = Get-Date
    $curlOut = & "$env:SystemRoot\System32\curl.exe" -s -o NUL -m 5 --connect-timeout 3 https://8.8.8.8:53/ 2>&1
    $curlExit = $LASTEXITCODE
    L ('  curl(8.8.8.8:53) exit=' + $curlExit + ' out=' + ($curlOut -join ' '))

    $pingOut = & "$env:SystemRoot\System32\ping.exe" -n 1 -w 1000 8.8.8.8 2>&1
    $pingExit = $LASTEXITCODE
    L ('  ping(8.8.8.8) exit=' + $pingExit + ' out=' + ($pingOut -join ' '))

    $tnc = Test-NetConnection 1.1.1.1 -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    L ('  Test-NetConnection 1.1.1.1:443 = ' + $tnc)

    $ocIds = @(Get-Process opencode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $ocConns = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                 Where-Object { $ocIds -contains $_.OwningProcess -and $_.RemoteAddress -notmatch '^(127\.|::1)' })
    L ('  opencode established external connections = ' + $ocConns.Count)
    foreach ($c in $ocConns | Select-Object -First 8) { L ('    ' + $c.RemoteAddress + ':' + $c.RemotePort + ' pid=' + $c.OwningProcess) }

    $blocked = (($curlExit -eq 7) -or ($curlExit -eq 28)) -and ($pingExit -ne 0) -and (-not $tnc)
    L ('  VERDICT non-whitelisted blocked = ' + $blocked)

    # 5) 回滚
    L '--- rollback ---'
    & $exe ctl rollback | ForEach-Object { L ('  ' + $_) }
    & "$env:SystemRoot\System32\sc.exe" stop NetGuard | Out-Null
    Start-Sleep 2
    $st = (& $exe ctl status 2>&1) -join "`n"
    L ('  post-rollback status: ' + (($st -split "`r?`n" | Where-Object { $_ -match 'filters' }) -join ' | '))

    $restored = Test-NetConnection 8.8.8.8 -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue
    L ('  after rollback Test-NetConnection 8.8.8.8:53 = ' + $restored)

    if ($blocked -and $ocConns.Count -gt 0) { L 'RESULT: WIN11 ENFORCEMENT OK (non-whitelisted blocked; opencode channel alive)' }
    elseif ($blocked) { L 'RESULT: non-whitelisted blocked, but no opencode connection observed at sample time' }
    else { L 'RESULT: INCONCLUSIVE/FAIL (see curl/ping/tnc above)' }
} catch {
    L ('EXCEPTION: ' + $_.Exception.Message)
} finally {
    try { if ($applied) { & $exe ctl rollback | Out-Null; & "$env:SystemRoot\System32\sc.exe" stop NetGuard | Out-Null } } catch { }
    try { Relax-Policy } catch { }
    if ($rbProc) { try { Stop-Process -Id $rbProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item $rbScript -Force -ErrorAction SilentlyContinue
    Set-Content -Path $done -Value (Get-Date -Format o) -Encoding UTF8
    L '=== done ==='
}
