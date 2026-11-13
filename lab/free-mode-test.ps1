param([string]$VmName = 'Win10-Pro-22H2')

$ErrorActionPreference = 'Stop'
$lab = 'C:\src\NetGuard\lab'
$log = Join-Path $lab 'free-mode-test.log'
$script:checks = @()
$script:fail = 0
function L([string]$m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
function Phase([string]$t) { L ''; L ('==== ' + $t + ' ====') }
function Check([string]$n, [bool]$ok, [string]$d = '') {
    if ($ok) { L ('PASS  ' + $n + '  ' + $d) } else { L ('FAIL  ' + $n + '  ' + $d); $script:fail++ }
    $script:checks += [pscustomobject]@{ Name = $n; Ok = $ok; Detail = $d }
}
'=== free mode e2e ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8

$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$vm = Get-VM -Name $VmName
if ($vm.State -ne 'Running') { Start-VM -Name $VmName }
$s = $null
for ($i = 0; $i -lt 40; $i++) {
    try { $s = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop; break } catch { Start-Sleep 5 }
}
if (-not $s) { throw 'PS Direct failed' }
L 'PS Direct connected'

Phase '1. clean old app + free mode + policy'
$clean = Invoke-Command -Session $s -ScriptBlock {
    # 先尝试正式关闭（幂等）
    if (Test-Path 'C:\NetGuard\free-mode.ps1') {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\free-mode.ps1' -Action Disable 2>&1 | Out-Null
    }
    foreach ($svc in @('NetGuard', 'ngdrv')) {
        & sc.exe stop $svc 2>&1 | Out-Null
        & sc.exe delete $svc 2>&1 | Out-Null
    }
    Get-Process NetGuard, NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Remove-Item 'C:\NetGuard', 'C:\ProgramData\NetGuard' -Recurse -Force -ErrorAction SilentlyContinue
    & reg.exe delete 'HKLM\SOFTWARE\NetGuard' /f 2>&1 | Out-Null

    # 兜底恢复：删掉残留规则、默认放行、启用所有放行规则、清空 AppLocker
    Remove-NetFirewallRule -Group 'NetGuard-FreeMode' -ErrorAction SilentlyContinue
    Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Allow -ErrorAction SilentlyContinue
    Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled False -ErrorAction SilentlyContinue |
        Enable-NetFirewallRule -ErrorAction SilentlyContinue
    $emptyAcl = Join-Path $env:TEMP 'empty-applocker.xml'
    [IO.File]::WriteAllText($emptyAcl, '<AppLockerPolicy Version="1" />', (New-Object Text.UTF8Encoding($false)))
    try { Set-AppLockerPolicy -XmlPolicy $emptyAcl -ErrorAction Stop } catch { }

    [pscustomobject]@{
        Svc = [bool](Get-Service NetGuard -ErrorAction SilentlyContinue)
        Drv = [bool](Get-Service ngdrv -ErrorAction SilentlyContinue)
        Dir = Test-Path 'C:\NetGuard'
        Data = Test-Path 'C:\ProgramData\NetGuard'
        Fw = @(Get-NetFirewallRule -Group 'NetGuard-FreeMode' -ErrorAction SilentlyContinue).Count
    }
}
Check 'old service/driver gone' ((-not $clean.Svc) -and (-not $clean.Drv)) ''
Check 'old dirs gone' ((-not $clean.Dir) -and (-not $clean.Data)) ''
Check 'no leftover free-mode rules' ($clean.Fw -eq 0) ('rules=' + $clean.Fw)

Phase '2. deploy build + scripts'
Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null } | Out-Null
foreach ($f in @(
        @{ Src = 'C:\src\NetGuard\build\NetGuard.exe'; Dst = 'C:\NetGuard\NetGuard.exe' },
        @{ Src = 'C:\src\NetGuard\build\NetGuardUI.exe'; Dst = 'C:\NetGuard\NetGuardUI.exe' },
        @{ Src = 'C:\src\NetGuard\install-netguard.ps1'; Dst = 'C:\NetGuard\install-netguard.ps1' },
        @{ Src = 'C:\src\NetGuard\uninstall-netguard.ps1'; Dst = 'C:\NetGuard\uninstall-netguard.ps1' },
        @{ Src = 'C:\src\NetGuard\free-mode.ps1'; Dst = 'C:\NetGuard\free-mode.ps1' }
    )) { Copy-Item $f.Src -ToSession $s -Destination $f.Dst -Force }
L 'files deployed'

Phase '3. baseline install (no free mode) + test policy'
$r0 = Invoke-Command -Session $s -ScriptBlock {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\install-netguard.ps1' 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($o -join "`n") }
}
Check 'baseline install exit=0' ($r0.Exit -eq 0) ('exit=' + $r0.Exit)

$h = Invoke-Command -Session $s -ScriptBlock {
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\NetGuard\ngblock.exe' -Force
    (& 'C:\NetGuard\NetGuard.exe' hash 'C:\NetGuard\ngblock.exe').Trim()
}
L ('ngblock hash=' + $h)

$policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=DNS
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1

[proc.1]
Name=ngblock
Path=C:\NetGuard\ngblock.exe
Sha256=$h
Endpoint=DNS
Enable=1
"@
[IO.File]::WriteAllText((Join-Path $lab 'policy-free-mode.ini'), ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $lab 'policy-free-mode.ini') -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$ap = Invoke-Command -Session $s -ScriptBlock {
    & 'C:\NetGuard\NetGuard.exe' sign 2>&1 | Out-Null
    (& 'C:\NetGuard\NetGuard.exe' ctl apply 2>&1) -join ' '
}
L ('apply: ' + $ap)
Check 'test policy applied' ($ap -match 'OK filters=6') $ap

Phase '4. reinstall with -FreeMode'
$r = Invoke-Command -Session $s -ScriptBlock {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\install-netguard.ps1' -FreeMode 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($o -join "`n") }
}
L ('installer -FreeMode exit=' + $r.Exit)
$r.Text -split "`r?`n" | Where-Object { $_ -match '\[\*\]|\[x\]|\[!\]|免费模式|防火墙|AppLocker|服务状态|完成' } | ForEach-Object { L ('  ' + $_) }
Check 'install -FreeMode exit=0' ($r.Exit -eq 0) ('exit=' + $r.Exit)

$st = Invoke-Command -Session $s -ScriptBlock {
    $n = Get-Service NetGuard -ErrorAction SilentlyContinue
    $a = Get-Service AppIDSvc -ErrorAction SilentlyContinue
    $rules = @(Get-NetFirewallRule -Group 'NetGuard-FreeMode' -ErrorAction SilentlyContinue)
    $profiles = @(Get-NetFirewallProfile -Profile Domain, Private, Public)
    $acl = ''
    try { $acl = [string](Get-AppLockerPolicy -Effective -Xml) } catch { }
    $state = $null
    if (Test-Path 'C:\ProgramData\NetGuard\freemode-state.json') {
        $state = Get-Content 'C:\ProgramData\NetGuard\freemode-state.json' -Raw | ConvertFrom-Json
    }
    [pscustomobject]@{
        NetGuard = if ($n) { $n.Status.ToString() } else { 'absent' }
        AppId = if ($a) { $a.Status.ToString() } else { 'absent' }
        Rules = $rules.Count
        RuleNames = ($rules | Select-Object -ExpandProperty DisplayName) -join ' | '
        Profiles = ($profiles | ForEach-Object { $_.Name + '=' + $_.DefaultOutboundAction }) -join '; '
        AclHit = ($acl -match 'Description="NetGuard:')
        AclCount = ([regex]::Matches($acl, 'Description="NetGuard:')).Count
        State = [bool]$state
        Disabled = if ($state) { @($state.DisabledBuiltinRules).Count } else { 0 }
    }
}
L ('status: svc=' + $st.NetGuard + ' appid=' + $st.AppId + ' rules=' + $st.Rules + ' profiles=' + $st.Profiles)
L ('acl hit=' + $st.AclHit + ' count=' + $st.AclCount + ' disabledBuiltin=' + $st.Disabled)
Check 'NetGuard service Running' ($st.NetGuard -eq 'Running') $st.NetGuard
Check 'free-mode firewall rules created' ($st.Rules -ge 2) ('rules=' + $st.Rules)
Check 'default outbound Block (all profiles)' ($st.Profiles -match 'Domain=Block' -and $st.Profiles -match 'Private=Block' -and $st.Profiles -match 'Public=Block') $st.Profiles
Check 'state file written' ($st.State -eq $true) ''
Check 'builtin outbound rules disabled' ($st.Disabled -gt 0) ('count=' + $st.Disabled)

Phase '5. enforcement'
$correct = Invoke-Command -Session $s -ScriptBlock {
    $c = & 'C:\NetGuard\ngblock.exe' -s -o NUL -m 5 --connect-timeout 3 https://8.8.8.8:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($c -join ' ') }
}
$other = Invoke-Command -Session $s -ScriptBlock {
    $c = & 'C:\NetGuard\ngblock.exe' -s -o NUL -m 5 --connect-timeout 3 https://114.114.114.114:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($c -join ' ') }
}
$syscurl = Invoke-Command -Session $s -ScriptBlock {
    $c = & "$env:SystemRoot\System32\curl.exe" -s -o NUL -m 5 --connect-timeout 3 https://8.8.8.8:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($c -join ' ') }
}
L ('correct=' + $correct.Exit + ' other=' + $other.Exit + ' syscurl=' + $syscurl.Exit)
Check 'whitelisted program allowed' ($correct.Exit -ne 7 -and $correct.Exit -ne 28) ('exit=' + $correct.Exit)
Check 'other destination blocked by firewall' ($other.Exit -in @(7, 28)) ('exit=' + $other.Exit)
Check 'non-whitelisted program blocked by firewall' ($syscurl.Exit -in @(7, 28)) ('exit=' + $syscurl.Exit)

# 复制到另一个路径：防火墙按“程序路径”绑定，副本不应被放行
$copy = Invoke-Command -Session $s -ScriptBlock {
    Copy-Item 'C:\NetGuard\ngblock.exe' 'C:\NetGuard\ngcopy.exe' -Force
    $c = & 'C:\NetGuard\ngcopy.exe' -s -o NUL -m 5 --connect-timeout 3 https://8.8.8.8:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($c -join ' ') }
}
L ('copied program exit=' + $copy.Exit)
Check 'copied/renamed program blocked by firewall' ($copy.Exit -in @(7, 28)) ('exit=' + $copy.Exit)

# 管理工具本身必须仍可运行（安装时把它加入白名单）
$self = Invoke-Command -Session $s -ScriptBlock {
    try {
        $p = Start-Process -FilePath 'C:\NetGuard\NetGuard.exe' -ArgumentList @('status') -PassThru -ErrorAction Stop
        $ok = $p.WaitForExit(10000)
        if (-not $ok) { $p.Kill() }
        [pscustomobject]@{ Started = $true; Exit = $p.ExitCode }
    } catch { [pscustomobject]@{ Started = $false; Exit = -1; Err = $_.Exception.Message } }
}
L ('NetGuard.exe launched=' + $self.Started + ' exit=' + $self.Exit)
Check 'NetGuard management exe still allowed' ($self.Started -eq $true) ('exit=' + $self.Exit)

Phase '6. uninstall'
$u = Invoke-Command -Session $s -ScriptBlock {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\uninstall-netguard.ps1' 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($o -join "`n") }
}
L ('uninstall exit=' + $u.Exit)
$u.Text -split "`r?`n" | Where-Object { $_ -match '\[\*\]|\[!\]|免费模式|恢复|重新启用' } | ForEach-Object { L ('  ' + $_) }
Check 'uninstall exit=0' ($u.Exit -eq 0) ('exit=' + $u.Exit)

$post = Invoke-Command -Session $s -ScriptBlock {
    $rules = @(Get-NetFirewallRule -Group 'NetGuard-FreeMode' -ErrorAction SilentlyContinue)
    $profiles = @(Get-NetFirewallProfile -Profile Domain, Private, Public)
    $acl = ''
    try { $acl = [string](Get-AppLockerPolicy -Effective -Xml) } catch { }
    [pscustomobject]@{
        Svc = [bool](Get-Service NetGuard -ErrorAction SilentlyContinue)
        Rules = $rules.Count
        Profiles = ($profiles | ForEach-Object { $_.Name + '=' + $_.DefaultOutboundAction }) -join '; '
        AclCount = ([regex]::Matches($acl, 'Description="NetGuard:')).Count
        State = Test-Path 'C:\ProgramData\NetGuard\freemode-state.json'
    }
}
L ('post: rules=' + $post.Rules + ' profiles=' + $post.Profiles + ' acl=' + $post.AclCount + ' state=' + $post.State)
Check 'after uninstall: free-mode rules gone' ($post.Rules -eq 0) ('rules=' + $post.Rules)
Check 'after uninstall: default outbound Allow' ($post.Profiles -match 'Domain=Allow' -and $post.Profiles -match 'Private=Allow' -and $post.Profiles -match 'Public=Allow') $post.Profiles
Check 'after uninstall: state file gone' ($post.State -eq $false) ''
Check 'after uninstall: service gone' (-not $post.Svc) ''

$net = Invoke-Command -Session $s -ScriptBlock { (Test-NetConnection 8.8.8.8 -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue) }
Check 'after uninstall: network restored' ($net -eq $true) ('tnc=' + $net)

Remove-PSSession $s -ErrorAction SilentlyContinue
Phase 'SUMMARY'
L ("total checks={0} failed={1}" -f $script:checks.Count, $script:fail)
$script:checks | ForEach-Object { L ("  [{0}] {1} {2}" -f $(if ($_.Ok) { 'OK' } else { 'XX' }), $_.Name, $_.Detail) }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
