# 清空旧版 NetGuard -> 重新部署当前构建 -> 端到端真实功能验证（Win10 22H2 客户机）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File C:\src\NetGuard\lab\deploy-and-test-win10.ps1
# 说明: 本机 Microsoft.PowerShell.Security 的 TypeData 损坏，ConvertTo-SecureString 不可用，
#       所以手工构造 SecureString。

param([string]$VmName = 'Win10-Pro-22H2')

$ErrorActionPreference = 'Stop'
$lab = 'C:\src\NetGuard\lab'
$log = Join-Path $lab 'deploy-test-win10.log'
$script:checks = @()

function HashFile([string]$p) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::OpenRead($p)
        try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}
function L([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    $line | Out-File -FilePath $log -Append -Encoding utf8
    Write-Host $line
}
function Phase([string]$t) { L ''; L ('==== ' + $t + ' ====') }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { L ("PASS  {0}  {1}" -f $name, $detail) } else { L ("FAIL  {0}  {1}" -f $name, $detail); $script:fail++ }
    $script:checks += [pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }
}
$script:fail = 0
'=== NetGuard clean-deploy-e2e @ ' + (Get-Date -Format o) + ' ===' | Out-File -FilePath $log -Encoding utf8

# ---------------------------------------------------------------- 连接客户机
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)

$vm = Get-VM -Name $VmName
if ($vm.State -ne 'Running') { Start-VM -Name $VmName }
for ($i = 0; $i -lt 30; $i++) {
    try { $script:s = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop; break }
    catch { Start-Sleep 5 }
}
if (-not $script:s) { throw 'PowerShell Direct 连接失败' }
L ('PS Direct connected to ' + $VmName)

function RunExe([string]$path, [string]$argstr) {
    Invoke-Command -Session $script:s -ScriptBlock {
        param($p, $a)
        $o = Join-Path $env:TEMP 'ng-run.out'
        $e = Join-Path $env:TEMP 'ng-run.err'
        Remove-Item $o, $e -ErrorAction SilentlyContinue
        $pr = Start-Process -FilePath $p -ArgumentList $a -NoNewWindow -Wait -PassThru `
              -RedirectStandardOutput $o -RedirectStandardError $e
        $t = @()
        if (Test-Path $o) { $t += Get-Content $o -Encoding Default }
        if (Test-Path $e) { $t += Get-Content $e -Encoding Default }
        [pscustomobject]@{ ExitCode = $pr.ExitCode; Text = ($t -join "`n") }
    } -ArgumentList $path, $argstr
}
function Probe([string]$ip, [int]$port, [int]$timeout = 2500) {
    Invoke-Command -Session $script:s -ScriptBlock {
        param($ip, $port, $timeout)
        $sock = $null
        try {
            $sock = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork,
                                                [Net.Sockets.SocketType]::Stream,
                                                [Net.Sockets.ProtocolType]::Tcp)
            $ar = $sock.BeginConnect([Net.IPAddress]::Parse($ip), $port, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($timeout)) { return 'TimedOut' }
            try { $sock.EndConnect($ar); return 'Connected' }
            catch { return $_.Exception.InnerException.SocketErrorCode.ToString() }
        } finally { if ($sock) { $sock.Close() } }
    } -ArgumentList $ip, $port, $timeout
}
function Ctl([string]$cmd) {
    $r = RunExe 'C:\NetGuard\NetGuard.exe' ('ctl ' + $cmd)
    $vals = @{}
    foreach ($ln in ($r.Text -split "`r?`n")) {
        if ($ln -match '^([a-z_]+)=(.*)$') { $vals[$Matches[1]] = $Matches[2] }
    }
    [pscustomobject]@{ ExitCode = $r.ExitCode; Text = $r.Text; Vals = $vals }
}

# ---------------------------------------------------------------- 1. 清理旧应用
Phase '1. clean old NetGuard'
$before = Invoke-Command -Session $script:s -ScriptBlock {
    $svc = Get-Service -Name NetGuard -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Service        = if ($svc) { $svc.Status.ToString() } else { 'absent' }
        Dir            = Test-Path 'C:\NetGuard'
        Data           = Test-Path 'C:\ProgramData\NetGuard'
        RegKey         = [bool](Test-Path 'HKLM:\SOFTWARE\NetGuard')
        Proc           = @(Get-Process NetGuard, NetGuardUI -ErrorAction SilentlyContinue).Count
        FiltersFile    = if (Test-Path 'C:\ProgramData\NetGuard\filters.txt') { (Get-Content 'C:\ProgramData\NetGuard\filters.txt').Count } else { -1 }
    }
}
L ("before: service={0} dir={1} data={2} reg={3} proc={4} filters_lines={5}" -f $before.Service, $before.Dir, $before.Data, $before.RegKey, $before.Proc, $before.FiltersFile)

Invoke-Command -Session $script:s -ScriptBlock {
    if (Get-Service NetGuard -ErrorAction SilentlyContinue) {
        & sc.exe stop NetGuard | Out-Null
        Start-Sleep 2
        & sc.exe delete NetGuard | Out-Null
        Start-Sleep 2
    }
    Get-Process NetGuard, NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    Remove-Item 'C:\NetGuard' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item 'C:\ProgramData\NetGuard' -Recurse -Force -ErrorAction SilentlyContinue
    & reg.exe delete 'HKLM\SOFTWARE\NetGuard' /f 2>&1 | Out-Null
    # 开始菜单/桌面残留快捷方式
    Get-ChildItem 'C:\Users\freeze\Desktop','C:\ProgramData\Microsoft\Windows\Start Menu\Programs',
                  'C:\Users\freeze\AppData\Roaming\Microsoft\Windows\Start Menu\Programs' -Recurse -Filter '*NetGuard*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    'cleaned'
} | ForEach-Object { L ('  ' + $_) }

$after = Invoke-Command -Session $script:s -ScriptBlock {
    [pscustomobject]@{
        Service = [bool](Get-Service NetGuard -ErrorAction SilentlyContinue)
        Dir     = Test-Path 'C:\NetGuard'
        Data    = Test-Path 'C:\ProgramData\NetGuard'
        RegKey  = [bool](Test-Path 'HKLM:\SOFTWARE\NetGuard')
        Proc    = @(Get-Process NetGuard, NetGuardUI -ErrorAction SilentlyContinue).Count
    }
}
Check 'old service removed'        (-not $after.Service) ''
Check 'old C:\NetGuard removed'    (-not $after.Dir) ''
Check 'old ProgramData removed'    (-not $after.Data) ''
Check 'old registry key removed'   (-not $after.RegKey) ''
Check 'old processes gone'         ($after.Proc -eq 0) ("count=$($after.Proc)")

# ---------------------------------------------------------------- 2. 投放当前构建
Phase '2. deploy current build'
Invoke-Command -Session $script:s -ScriptBlock { New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null }
$files = @(
    @{ Src = 'C:\src\NetGuard\build\NetGuard.exe';          Dst = 'C:\NetGuard\NetGuard.exe' },
    @{ Src = 'C:\src\NetGuard\build\NetGuardUI.exe';        Dst = 'C:\NetGuard\NetGuardUI.exe' },
    @{ Src = 'C:\src\NetGuard\install-netguard.ps1';        Dst = 'C:\NetGuard\install-netguard.ps1' },
    @{ Src = 'C:\src\NetGuard\uninstall-netguard.ps1';      Dst = 'C:\NetGuard\uninstall-netguard.ps1' }
)
foreach ($f in $files) {
    Copy-Item $f.Src -ToSession $script:s -Destination $f.Dst -Force
}
# 业务程序用系统 curl 的副本（真实的网络客户端），两个进程绑定不同业务地址
Invoke-Command -Session $script:s -ScriptBlock {
    Copy-Item 'C:\Windows\System32\curl.exe' 'C:\NetGuard\biz.exe' -Force
    Copy-Item 'C:\Windows\System32\curl.exe' 'C:\NetGuard\biz2.exe' -Force
    Get-ChildItem 'C:\NetGuard' | Select-Object Name, Length | ForEach-Object { "deployed: $($_.Name) $($_.Length)" }
} | ForEach-Object { L ('  ' + $_) }

$hashHost = HashFile 'C:\src\NetGuard\build\NetGuard.exe'
$hashGuest = Invoke-Command -Session $script:s -ScriptBlock {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead('C:\NetGuard\NetGuard.exe')
    try { (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $fs.Dispose(); $sha.Dispose() }
}
Check 'deployed NetGuard.exe sha256 matches build' ($hashHost -eq $hashGuest) $hashHost

# ---------------------------------------------------------------- 3. 基线（无管控）
Phase '3. purge legacy WFP state + baseline connectivity'
# 旧版本（持久化过滤器）留下的拦截规则会跨重启继续断网，先清理
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'purge'
L ('  purge: ' + (($r.Text -split "`r?`n") -join ' | '))
Check 'legacy persistent filters purged' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
Start-Sleep 2
$pp = Probe '1.1.1.1' 443
Check 'no NetGuard filters left before install (connect not denied)' ($pp -ne 'AccessDenied') $pp

$r = RunExe 'C:\NetGuard\NetGuard.exe' 'selftest'
L ("  selftest(no filters): exit={0}  {1}" -f $r.ExitCode, (($r.Text -split "`r?`n") | Select-Object -Last 1))
# 发布版（NG_TRIAL_ENABLED=1）在未登记试用前 selftest 会被拒绝（exit=6）；
# 开发版（NG_TRIAL_ENABLED=0）会直接运行，未装过滤时会 exit=2（有泄漏）。
Check 'selftest runs or is trial-gated' ($r.ExitCode -eq 2 -or $r.ExitCode -eq 6) ("exit=$($r.ExitCode)")

$b1 = RunExe 'C:\NetGuard\biz.exe'  '-s -o NUL -m 6 --connect-timeout 4 https://8.8.8.8:53/'
$b2 = RunExe 'C:\NetGuard\biz2.exe' '-s -o NUL -m 6 --connect-timeout 4 https://180.101.49.12/'
$b3 = RunExe 'C:\Windows\System32\curl.exe' '-s -o NUL -m 6 --connect-timeout 4 https://8.8.8.8:53/'
L ("  baseline curl exits: biz->8.8.8.8:53={0}, biz2->baidu={1}, curl->8.8.8.8:53={2}" -f $b1.ExitCode, $b2.ExitCode, $b3.ExitCode)
Check 'baseline biz.exe can connect'   ($b1.ExitCode -ne 7) ("exit=$($b1.ExitCode)")
Check 'baseline biz2.exe can connect'  ($b2.ExitCode -ne 7) ("exit=$($b2.ExitCode)")
Check 'baseline curl.exe can connect'  ($b3.ExitCode -ne 7) ("exit=$($b3.ExitCode)")

$netinfo = Invoke-Command -Session $script:s -ScriptBlock {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' } |
           ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)" }
    $dns = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses.Count -gt 0 } | Select-Object -First 1).ServerAddresses -join ','
    "ip: $($ips -join ' ; ')  dns: $dns"
}
L ('  ' + $netinfo)

# ---------------------------------------------------------------- 4. 安装（当前 install 脚本）
Phase '4. install via install-netguard.ps1'
$r = RunExe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
     '-NoProfile -ExecutionPolicy Bypass -File C:\NetGuard\install-netguard.ps1'
$r.Text -split "`r?`n" | Where-Object { $_ -match '\[\*\]|\[x\]|\[!\]|完成|状态' } | Select-Object -Last 18 | ForEach-Object { L ('  ' + $_) }
Check 'install script exit=0' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")

$svc = Invoke-Command -Session $script:s -ScriptBlock {
    $s = Get-Service NetGuard -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Exists = [bool]$s
        Status = if ($s) { $s.Status.ToString() } else { 'absent' }
        Start  = if ($s) { $s.StartType.ToString() } else { '' }
        Sddl   = ((& sc.exe sdshow NetGuard) -join '')
    }
}
Check 'service installed and running' ($svc.Exists -and $svc.Status -eq 'Running') ("status=$($svc.Status) start=$($svc.Start)")
Check 'service DACL hardened (no Users ACE)' ($svc.Sddl -notmatch ';;;BU\)' -and $svc.Sddl -match ';;;SY\)' -and $svc.Sddl -match ';;;BA\)') $svc.Sddl

$st = Ctl 'status'
$st.Text -split "`r?`n" | ForEach-Object { L ('  ' + $_) }
$filters = [int]$st.Vals['filters']
Check 'service applies filters at startup'   ($filters -ge 6) ("filters=$filters")
Check 'default deny active'                  ($st.Vals['default_deny'] -eq '1') ''
Check 'filters live == expected'             ($st.Vals['filters_live'] -eq $st.Vals['filters']) ("live=$($st.Vals['filters_live'])")
Check 'policy key present'                   ($st.Vals['key_ok'] -eq '1') ''
Check 'policy HMAC valid'                    ($st.Vals['hmac_ok'] -eq '1') ''
Check 'trial registered (~60 days)'          ([int]$st.Vals['trial_days'] -ge 58) ("days=$($st.Vals['trial_days'])")

$r = RunExe 'C:\NetGuard\NetGuard.exe' 'selftest'
Check 'sample policy blocks every outbound target (selftest exit=0)' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")

# 安装脚本加固：数据目录 ACL / admin.dat
$acl = Invoke-Command -Session $script:s -ScriptBlock {
    $d = (Get-Acl 'C:\ProgramData\NetGuard').Access | ForEach-Object { "$($_.IdentityReference)=$($_.FileSystemRights)" }
    $svc = (Get-CimInstance Win32_Service -Filter "Name='NetGuard'")
    [pscustomobject]@{
        Acl = ($d -join ' | ')
        Path = $svc.PathName
        Account = $svc.StartName
        Failure = ((& sc.exe qfailure NetGuard) -join ' ')
    }
}
L ('  data ACL: ' + $acl.Acl)
Check 'data dir users have read-only' ($acl.Acl -match 'Users=ReadAndExecute' -and $acl.Acl -notmatch 'Users=.*(Write|Modify|FullControl)') ''
Check 'service runs as LocalSystem' ($acl.Account -eq 'LocalSystem') $acl.Account
L ('  failure actions: ' + $acl.Failure)
Check 'service failure actions configured (restart 5s/15s/60s)' `
      ($acl.Failure -match '5000' -and $acl.Failure -match '15000' -and $acl.Failure -match '60000') ''

# ---------------------------------------------------------------- 5. UI 自检
Phase '5. management UI selftest'
$ui = RunExe 'C:\NetGuard\NetGuardUI.exe' '--selftest'
Start-Sleep 2
$uiRep = Invoke-Command -Session $script:s -ScriptBlock {
    if (Test-Path 'C:\ProgramData\NetGuard\ui-selftest.txt') { Get-Content 'C:\ProgramData\NetGuard\ui-selftest.txt' -Encoding UTF8 } else { 'MISSING' }
}
$uiRep -split "`r?`n" | Where-Object { $_ } | ForEach-Object { L ('  ' + $_) }
$uiText = $uiRep -join "`n"
Check 'UI window created'          ($uiText -match 'main_window=1') ''
Check 'UI listviews have 5 columns' ($uiText -match 'listEp_cols=5' -and $uiText -match 'listPr_cols=5') ''
Check 'UI checkboxes + edits + statusbar' ($uiText -match 'chkDeny=1 chkDhcp=1 chkLoop=1' -and $uiText -match 'edtLan=1 edtDns=1 edtTemp=1' -and $uiText -match 'statusbar=1') ''
Check 'UI shows installed policy'  ($uiText -match 'policy_eps=2 policy_procs=1') ''
# 说明：PS Direct 会话是 session 0，GDI 截图会得到空白；界面像素级验收需要在交互桌面
# 用 --screenshot（见 docs/新手教程.md 的已有截图）。这里以 --selftest 的结构报告为准。

# ---------------------------------------------------------------- 6. 部署测试策略
Phase '6. deploy test policy (2 endpoints / 2 programs)'
$h1 = (RunExe 'C:\NetGuard\NetGuard.exe' 'hash C:\NetGuard\biz.exe').Text.Trim()
$h2 = (RunExe 'C:\NetGuard\NetGuard.exe' 'hash C:\NetGuard\biz2.exe').Text.Trim()
L ("  biz.exe  sha256=$h1")
L ("  biz2.exe sha256=$h2")
Check 'guest computes sha256 via NetGuard hash' ($h1 -match '^[0-9A-Fa-f]{64}$' -and $h2 -match '^[0-9A-Fa-f]{64}$') ''

$policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=TestDNS
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1

[ep.2]
Name=TestBaidu
Cidr=180.101.49.12/32
Ports=443
Proto=TCP
Enable=1

[proc.1]
Name=biz-dns
Path=C:\NetGuard\biz.exe
Sha256=$h1
Endpoint=TestDNS
Enable=1

[proc.2]
Name=biz2-baidu
Path=C:\NetGuard\biz2.exe
Sha256=$h2
Endpoint=TestBaidu
Enable=1
"@
$polHost = Join-Path $lab 'policy-e2e.ini'
[IO.File]::WriteAllText($polHost, ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item $polHost -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
L ('  sign: ' + (($r.Text -split "`r?`n") -join ' | '))
Check 'unsigned policy re-signed by admin' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'verify'
Check 'policy passes verify (format+signature)' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
$ap = Ctl 'apply'
L ('  ctl apply: ' + ($ap.Text -split "`r?`n")[0])
Check 'ctl apply pushes 2 endpoint+program filters' ($ap.Text -match 'OK filters=7') $ap.Text

# ---------------------------------------------------------------- 7. 功能矩阵
Phase '7. enforcement matrix'
$a1 = RunExe 'C:\NetGuard\biz.exe'  '-s -o NUL -m 6 --connect-timeout 4 https://8.8.8.8:53/'
$a2 = RunExe 'C:\NetGuard\biz.exe'  '-s -o NUL -m 6 --connect-timeout 4 https://180.101.49.12/'
$a3 = RunExe 'C:\NetGuard\biz2.exe' '-s -o NUL -m 6 --connect-timeout 4 https://180.101.49.12/'
$a4 = RunExe 'C:\NetGuard\biz2.exe' '-s -o NUL -m 6 --connect-timeout 4 https://8.8.8.8:53/'
$a5 = RunExe 'C:\Windows\System32\curl.exe' '-s -o NUL -m 6 --connect-timeout 4 https://8.8.8.8:53/'
L ("  exits: biz->dns={0}  biz->baidu={1}  biz2->baidu={2}  biz2->dns={3}  curl->dns={4}" -f $a1.ExitCode, $a2.ExitCode, $a3.ExitCode, $a4.ExitCode, $a5.ExitCode)
Check 'whitelisted biz.exe -> its endpoint: ALLOWED'      ($a1.ExitCode -ne 7) ("exit=$($a1.ExitCode)")
Check 'biz.exe -> other endpoint: BLOCKED'                ($a2.ExitCode -eq 7) ("exit=$($a2.ExitCode)")
Check 'whitelisted biz2.exe -> its endpoint: ALLOWED'     ($a3.ExitCode -ne 7) ("exit=$($a3.ExitCode)")
Check 'biz2.exe -> other endpoint: BLOCKED'               ($a4.ExitCode -eq 7) ("exit=$($a4.ExitCode)")
Check 'non-whitelisted curl.exe -> same endpoint: BLOCKED' ($a5.ExitCode -eq 7) ("exit=$($a5.ExitCode)")

$p1 = Probe '180.101.49.12' 443
$p2 = Probe '1.1.1.1' 443
$p3 = Probe '127.0.0.1' 135
$p4 = Probe '8.8.8.8' 53
L ("  raw socket: baidu={0}  cloudflare={1}  loopback135={2}  dns53={3}" -f $p1, $p2, $p3, $p4)
Check 'unlisted destination denied (AccessDenied)' ($p2 -eq 'AccessDenied') $p2
Check 'loopback still allowed (not AccessDenied)' ($p3 -ne 'AccessDenied') $p3
Check 'unlisted program denied (AccessDenied)'     ($p4 -eq 'AccessDenied') $p4

$dns = Invoke-Command -Session $script:s -ScriptBlock {
    try { $x = Resolve-DnsName ('ng-' + [guid]::NewGuid().ToString('N') + '.example.com') -ErrorAction Stop; 'resolved:' + $x.Count }
    catch { 'dns-blocked' }
}
Check 'DNS blocked when no AllowDnsServer' ($dns -eq 'dns-blocked') $dns

$r = RunExe 'C:\NetGuard\NetGuard.exe' 'selftest'
Check 'selftest: 0 leaks while test policy active' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")

# ---------------------------------------------------------------- 8. 哈希防替换
Phase '8. hash lock / tamper response'
# 用 curl 副本 + 追加字节：文件仍是可执行的网络客户端，但 SHA-256 已变（模拟程序被替换）
Invoke-Command -Session $script:s -ScriptBlock {
    Copy-Item 'C:\Windows\System32\curl.exe' 'C:\NetGuard\biz.exe' -Force
    $fs = [IO.File]::Open('C:\NetGuard\biz.exe', 'Append')
    $b = [Text.Encoding]::ASCII.GetBytes('NG-TAMPER')
    $fs.Write($b, 0, $b.Length)
    $fs.Close()
    'biz.exe replaced with patched curl.exe (bytes appended)'
} | ForEach-Object { L ('  ' + $_) }
$hTampered = (RunExe 'C:\NetGuard\NetGuard.exe' 'hash C:\NetGuard\biz.exe').Text.Trim()
Check 'tampered binary hash differs from policy hash' ($hTampered -ne $h1) $hTampered
$a0 = RunExe 'C:\NetGuard\biz.exe' '-s -o NUL -m 6 --connect-timeout 4 https://8.8.8.8:53/'
L ("  before revocation tampered binary exit={0} (过滤器只绑定路径，哈希由看门狗巡检)" -f $a0.ExitCode)
L '  waiting up to 45s for watchdog ...'
$hashOk = $false
for ($i = 0; $i -lt 9; $i++) {
    Start-Sleep 5
    $st = Ctl 'status'
    L ("    t+{0}s filters={1} live={2}" -f (($i + 1) * 5), $st.Vals['filters'], $st.Vals['filters_live'])
    if ($st.Vals['filters'] -eq '6') { $hashOk = $true; break }
}
Check 'watchdog revokes tampered program (filters 7->6)' ($hashOk) ''
$polNow = Invoke-Command -Session $script:s -ScriptBlock { Get-Content 'C:\ProgramData\NetGuard\policy.ini' -Encoding UTF8 }
$procSec = ($polNow -join "`n")
Check 'policy disables tampered entry (Enable=0)' ($procSec -match 'Name=biz-dns[\s\S]*?Enable=0') ''
$audit = Invoke-Command -Session $script:s -ScriptBlock { Get-Content 'C:\ProgramData\NetGuard\audit.log' -Encoding UTF8 | Select-Object -Last 20 }
$auditTxt = $audit -join "`n"
$audit | ForEach-Object { L ('  ' + $_) }
Check 'audit logs hash-changed ALERT'   ($auditTxt -match 'hash-changed|hash mismatch|哈希') ''
Check 'audit logs revocation ACTION'    ($auditTxt -match 'revoked-mismatched-programs') ''
$a6 = RunExe 'C:\NetGuard\biz.exe' '-s -o NUL -m 6 --connect-timeout 4 https://8.8.8.8:53/'
Check 'tampered program can no longer use its endpoint' ($a6.ExitCode -eq 7) ("exit=$($a6.ExitCode)")

# ---------------------------------------------------------------- 9. 恢复 + 临时放行
Phase '9. restore policy then temp-allow test'
Invoke-Command -Session $script:s -ScriptBlock { Copy-Item 'C:\Windows\System32\curl.exe' 'C:\NetGuard\biz.exe' -Force }
Copy-Item $polHost -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
$ap = Ctl 'apply'
Check 'policy restored to 7 filters' ($ap.Text -match 'OK filters=7') $ap.Text

$t = Ctl 'temp 1'
L ('  ctl temp 1: ' + (($t.Text -split "`r?`n")[0]))
Check 'IPC temp accepted' ($t.Text -match 'OK temp=1min') $t.Text
Start-Sleep 3
$st = Ctl 'status'
Check 'temp allow drops filters to 0' ($st.Vals['filters_live'] -eq '0') ("live=$($st.Vals['filters_live'])")
$p5 = Probe '1.1.1.1' 443
Check 'while temp allowing, blocked target reachable' ($p5 -ne 'AccessDenied') $p5
L '  waiting for temp expiry + watchdog tick (up to 110s) ...'
$tempBack = $false
for ($i = 0; $i -lt 22; $i++) {
    Start-Sleep 5
    $st = Ctl 'status'
    if ($st.Vals['filters'] -eq '7' -and $st.Vals['filters_live'] -eq '7') { $tempBack = $true; L ("    restored after ~{0}s" -f (($i + 1) * 5)); break }
}
Check 'temp expiry restores enforcement (7 filters)' ($tempBack) ("filters=$($st.Vals['filters']) live=$($st.Vals['filters_live'])")
$p6 = Probe '1.1.1.1' 443
Check 'after temp expiry target blocked again' ($p6 -eq 'AccessDenied') $p6

# ---------------------------------------------------------------- 10. 看门狗自愈
Phase '10. watchdog self-heal after filter removal'
$st = Ctl 'rollback'
Check 'manual rollback accepted' ($st.Text -match 'OK rolled-back') $st.Text
L '  watchdog must restore the filters by itself (up to 40s) ...'
$healed = $false
$sawZero = $false
for ($i = 0; $i -lt 8; $i++) {
    Start-Sleep 5
    $st = Ctl 'status'
    L ("    t+{0}s filters={1} live={2}" -f (($i + 1) * 5), $st.Vals['filters'], $st.Vals['filters_live'])
    if ($st.Vals['filters_live'] -eq '0') { $sawZero = $true }
    if ($st.Vals['filters'] -eq '7' -and $st.Vals['filters_live'] -eq '7') { $healed = $true; break }
}
Check 'watchdog re-applies missing filters automatically' ($healed) ''
$p7 = Probe '1.1.1.1' 443
Check 'enforcement is live again after self-heal' ($p7 -eq 'AccessDenied') $p7

# ---------------------------------------------------------------- 11. e2e 自测命令（服务停止时）
Phase '11. NetGuard.exe test (end-to-end self test)'
Invoke-Command -Session $script:s -ScriptBlock { & sc.exe stop NetGuard | Out-Null; Start-Sleep 3; (& sc.exe query NetGuard | Select-String 'STATE') -join '' } | ForEach-Object { L ('  ' + $_) }
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'test'
$r.Text -split "`r?`n" | Where-Object { $_ -match '==|基线|应用后|回滚后|ok|PASS|FAIL' } | ForEach-Object { L ('  ' + $_) }
Check 'NetGuard test: baseline->apply->block->rollback->restore (exit=0)' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
Invoke-Command -Session $script:s -ScriptBlock { & sc.exe start NetGuard | Out-Null; Start-Sleep 6; (& sc.exe query NetGuard | Select-String 'STATE') -join '' } | ForEach-Object { L ('  ' + $_) }
$st = Ctl 'status'
Check 'service re-applies policy after restart' ($st.Vals['filters'] -eq '7' -and $st.Vals['filters_live'] -eq '7') ("filters=$($st.Vals['filters']) live=$($st.Vals['filters_live'])")

# ---------------------------------------------------------------- 12. fail-closed（篡改策略）
Phase '12. fail-closed: tampered policy is refused'
Invoke-Command -Session $script:s -ScriptBlock {
    Copy-Item 'C:\ProgramData\NetGuard\policy.ini' 'C:\ProgramData\NetGuard\policy.bak' -Force
    $t = Get-Content 'C:\ProgramData\NetGuard\policy.ini' -Raw -Encoding UTF8
    $t = $t.Replace('Cidr=8.8.8.8/32', 'Cidr=9.9.9.9/32')
    [IO.File]::WriteAllText('C:\ProgramData\NetGuard\policy.ini', $t, (New-Object Text.UTF8Encoding($false)))
    'policy Cidr edited without re-signing'
} | ForEach-Object { L ('  ' + $_) }
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'verify'
Check 'verify rejects tampered policy' ($r.ExitCode -ne 0) ("exit=$($r.ExitCode)")
$ap = Ctl 'apply'
L ('  ctl apply on tampered policy: ' + (($ap.Text -split "`r?`n")[0]))
Check 'service refuses to apply tampered policy' ($ap.Text -match 'ERR') $ap.Text
$st = Ctl 'status'
Check 'existing filters untouched after rejected apply' ($st.Vals['filters_live'] -eq '7') ("live=$($st.Vals['filters_live'])")
Invoke-Command -Session $script:s -ScriptBlock {
    Copy-Item 'C:\ProgramData\NetGuard\policy.bak' 'C:\ProgramData\NetGuard\policy.ini' -Force
    Remove-Item 'C:\ProgramData\NetGuard\policy.bak' -Force
    'policy restored'
} | ForEach-Object { L ('  ' + $_) }
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'verify'
Check 'restored policy verifies again' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")

# ---------------------------------------------------------------- 13. 卸载 -> 重装
Phase '13. uninstall and reinstall lifecycle'
$r = RunExe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
     '-NoProfile -ExecutionPolicy Bypass -File C:\NetGuard\uninstall-netguard.ps1'
$r.Text -split "`r?`n" | Where-Object { $_ -match '\[\*\]|\[!\]' } | Select-Object -Last 10 | ForEach-Object { L ('  ' + $_) }
Check 'uninstall script exit=0' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
$post = Invoke-Command -Session $script:s -ScriptBlock {
    [pscustomobject]@{
        Service = [bool](Get-Service NetGuard -ErrorAction SilentlyContinue)
        Proc    = @(Get-Process NetGuard -ErrorAction SilentlyContinue).Count
        Filters = if (Test-Path 'C:\ProgramData\NetGuard\filters.txt') { (Get-Content 'C:\ProgramData\NetGuard\filters.txt').Count } else { -1 }
        Policy  = Test-Path 'C:\ProgramData\NetGuard\policy.ini'
        Key     = [bool]((Get-ItemProperty 'HKLM:\SOFTWARE\NetGuard' -ErrorAction SilentlyContinue).PolicyKey)
    }
}
Check 'after uninstall: service gone'  (-not $post.Service) ''
Check 'after uninstall: no process'    ($post.Proc -eq 0) ("count=$($post.Proc)")
Check 'after uninstall: filters.txt empty' ($post.Filters -eq 0) ("lines=$($post.Filters)")
Check 'after uninstall: policy kept'   ($post.Policy) ''
Check 'after uninstall: deployment key kept' ($post.Key) ''
$restored = Probe '1.1.1.1' 443
Check 'after uninstall: internet restored (not AccessDenied)' ($restored -ne 'AccessDenied') $restored

$r = RunExe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
     '-NoProfile -ExecutionPolicy Bypass -File C:\NetGuard\install-netguard.ps1'
Check 'reinstall script exit=0' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
$st = Ctl 'status'
Check 'reinstalled service running with 7 filters' ($st.Vals['filters'] -eq '7' -and $st.Vals['filters_live'] -eq '7') ("filters=$($st.Vals['filters']) live=$($st.Vals['filters_live'])")
Check 'key/hmac still valid after reinstall' ($st.Vals['key_ok'] -eq '1' -and $st.Vals['hmac_ok'] -eq '1') ''

# ---------------------------------------------------------------- 14. 恢复出厂样例策略
Phase '14. finalize: fresh sample policy + service running'
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'initpolicy'
Check 'initpolicy regenerates sample policy' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
Check 'sample policy signed with deployment key' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
$ap = Ctl 'apply'
Check 'sample policy applied (6 filters)' ($ap.Text -match 'OK filters=6') $ap.Text
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'selftest'
Check 'final selftest: 0 leaks' ($r.ExitCode -eq 0) ("exit=$($r.ExitCode)")
$st = Ctl 'status'
$st.Text -split "`r?`n" | ForEach-Object { L ('  ' + $_) }

Invoke-Command -Session $script:s -ScriptBlock {
    Remove-Item 'C:\NetGuard\biz.exe','C:\NetGuard\biz2.exe' -Force -ErrorAction SilentlyContinue
} | Out-Null
try {
    L '  deployment finished'
} catch { L ('  screenshot copy skipped: ' + $_.Exception.Message) }

Remove-PSSession $script:s

# ---------------------------------------------------------------- 汇总
Phase 'SUMMARY'
L ("total checks={0}  failed={1}" -f $script:checks.Count, $script:fail)
$script:checks | ForEach-Object { L ("  [{0}] {1} {2}" -f $(if ($_.Ok) { 'OK' } else { 'XX' }), $_.Name, $_.Detail) }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
