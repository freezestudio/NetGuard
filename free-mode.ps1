# NetGuard 免费模式（无需驱动/证书）
#   Windows 防火墙：出站默认阻止 + 按“程序 × 地址 × 端口”放行
#   AppLocker：按“精确程序路径”放行白名单程序（配合程序目录 ACL，
#             标准用户无法替换/改写；复制或改名后的程序启动即被拒）
#   注意：不使用 AppLocker 哈希规则 —— 本机实测 Win10 22H2 本地策略里
#   FileHashRule 会导致整个 Exe 集合不编译（策略看似生效但完全不拦）；
#   需要“连接瞬间哈希”时请安装可选驱动 drv\ngdrv.sys。
#
# 用法（管理员）：
#   powershell -ExecutionPolicy Bypass -File free-mode.ps1 -Action Enable
#   powershell -ExecutionPolicy Bypass -File free-mode.ps1 -Action Status
#   powershell -ExecutionPolicy Bypass -File free-mode.ps1 -Action Disable
#
# 可选参数：
#   -PolicyPath <path>      默认 %ProgramData%\NetGuard\policy.ini
#   -UseAppLocker           额外启用 AppLocker 精确路径规则（实验性；部分 Win10
#                           本地策略环境无法可靠编译，默认关闭）
#   -KeepBuiltinRules       不关闭 Windows 自带出站放行规则（默认关闭，更严格）
#   -DryRun                 只打印将要执行的操作
#
# 所有改动都记录在 %ProgramData%\NetGuard\freemode-state.json，
# -Action Disable 会恢复防火墙默认动作、重新启用被关闭的规则、还原 AppLocker 策略。

param(
    [ValidateSet('Enable', 'Disable', 'Status')]
    [string]$Action = 'Status',
    [string]$PolicyPath = (Join-Path $env:ProgramData 'NetGuard\policy.ini'),
    [switch]$UseAppLocker,
    [switch]$KeepBuiltinRules,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$data = Join-Path $env:ProgramData 'NetGuard'
$statePath = Join-Path $data 'freemode-state.json'
$logPath = Join-Path $data 'freemode.log'
$aclBackup = Join-Path $data 'applocker-backup.xml'
$aclApplied = Join-Path $data 'applocker-netguard.xml'
$group = 'NetGuard-FreeMode'

function Say([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host "[*] $m"
    try {
        if (-not (Test-Path $data)) { New-Item -ItemType Directory -Path $data -Force | Out-Null }
        Add-Content -Path $logPath -Value $line -Encoding UTF8
    } catch { }
}
function Warn([string]$m) {
    $line = '{0}  [WARN] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host "[!] $m"
    try { Add-Content -Path $logPath -Value $line -Encoding UTF8 } catch { }
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '需要以管理员身份运行'
    }
}

function Read-Ini([string]$path) {
    $ini = @{}
    if (-not (Test-Path $path)) { throw "未找到策略文件: $path" }
    $section = ''
    foreach ($raw in Get-Content -Path $path -Encoding UTF8) {
        $t = $raw.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t.StartsWith('[')) {
            $e = $t.IndexOf(']')
            if ($e -gt 0) {
                $section = $t.Substring(1, $e - 1).Trim().ToLowerInvariant()
                if (-not $ini.ContainsKey($section)) { $ini[$section] = @{} }
            }
            continue
        }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1 -or $section -eq '') { continue }
        $k = $t.Substring(0, $eq).Trim().ToLowerInvariant()
        $v = $t.Substring($eq + 1).Trim()
        $ini[$section][$k] = $v
    }
    return $ini
}

function Get-Val($sec, [string]$key, [string]$default = '') {
    if ($null -eq $sec) { return $default }
    if ($sec.ContainsKey($key.ToLowerInvariant())) { return [string]$sec[$key.ToLowerInvariant()] }
    return $default
}
function Get-Bool($sec, [string]$key, [bool]$default = $false) {
    $v = Get-Val $sec $key ''
    if ($v -eq '') { return $default }
    return ($v -eq '1' -or $v -ieq 'true' -or $v -ieq 'yes')
}

function Get-Policy {
    $ini = Read-Ini $PolicyPath
    $general = $ini['general']
    if ($null -eq $general) { throw '策略缺少 [general]' }

    $eps = @{}
    foreach ($k in $ini.Keys) {
        if ($k -notmatch '^ep\.') { continue }
        $s = $ini[$k]
        $name = Get-Val $s 'name' ''
        if ($name -eq '') { continue }
        $eps[$name.ToLowerInvariant()] = [pscustomobject]@{
            Name    = $name
            Cidr    = Get-Val $s 'cidr' ''
            Ports   = Get-Val $s 'ports' ''
            Proto   = Get-Val $s 'proto' 'ANY'
            Enabled = Get-Bool $s 'enable' $true
        }
    }

    $procs = @()
    foreach ($k in $ini.Keys) {
        if ($k -notmatch '^proc\.') { continue }
        $s = $ini[$k]
        $procs += [pscustomobject]@{
            Name     = Get-Val $s 'name' ''
            Path     = Get-Val $s 'path' ''
            Sha256   = (Get-Val $s 'sha256' '').ToUpperInvariant()
            Endpoint = Get-Val $s 'endpoint' ''
            Enabled  = Get-Bool $s 'enable' $true
        }
    }

    return [pscustomobject]@{
        DefaultDeny    = Get-Bool $general 'defaultdeny' $true
        AllowDhcp      = Get-Bool $general 'allowdhcp' $true
        AllowLoopback  = Get-Bool $general 'allowloopback' $true
        AllowDnsServer = Get-Val $general 'allowdnsserver' ''
        LanAllow       = Get-Val $general 'lanallow' ''
        LanAnyProc     = Get-Bool $general 'allowlananyprocess' $false
        Eps            = $eps
        Procs          = $procs
    }
}

function New-AllowRule([string]$display, [string]$program, $remote, $ports, [string]$proto, [string]$service = '', $localPort = $null) {
    if ($DryRun) { Say ("[dry] allow: {0} | prog={1} | remote={2} | ports={3} | proto={4}" -f $display, $program, ($remote -join ','), ($ports -join ','), $proto); return }
    $p = @{
        DisplayName = 'NetGuard: ' + $display
        Group       = $group
        Direction   = 'Outbound'
        Action      = 'Allow'
        Profile     = 'Any'
    }
    if ($program -and $program -ne '*') { $p['Program'] = $program }
    if ($remote -and $remote.Count -gt 0) { $p['RemoteAddress'] = $remote }
    if ($ports -and $ports.Count -gt 0) { $p['RemotePort'] = $ports }
    if ($localPort -and $localPort.Count -gt 0) { $p['LocalPort'] = $localPort }
    if ($proto) { $p['Protocol'] = $proto }
    if ($service) { $p['Service'] = $service }
    $r = New-NetFirewallRule @p
    Say ("added firewall rule: {0} ({1})" -f $r.DisplayName, $r.Name)
}

function Remove-FreeModeRules {
    $rules = @(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) { return 0 }
    if ($DryRun) { Say ("[dry] remove {0} firewall rule(s)" -f $rules.Count); return $rules.Count }
    $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Say ("removed {0} firewall rule(s)" -f $rules.Count)
    return $rules.Count
}

function Get-AppLockerXml {
    if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)) { return $null }
    try {
        $xml = Get-AppLockerPolicy -Local -Xml -ErrorAction Stop
        if (-not $xml) { $xml = '<AppLockerPolicy Version="1" />' }
        return [string]$xml
    } catch {
        Warn ('读取 AppLocker 策略失败: ' + $_.Exception.Message)
        return $null
    }
}

function Add-PathRule($doc, $col, [string]$path, [string]$name) {
    $r = $doc.CreateElement('FilePathRule')
    $r.SetAttribute('Id', [guid]::NewGuid().ToString())
    $r.SetAttribute('Name', $name)
    $r.SetAttribute('Description', 'NetGuard default path rule')
    $r.SetAttribute('UserOrGroupSid', 'S-1-1-0')
    $r.SetAttribute('Action', 'Allow')
    $conds = $doc.CreateElement('Conditions')
    $c = $doc.CreateElement('FilePathCondition')
    $c.SetAttribute('Path', $path)
    $conds.AppendChild($c) | Out-Null
    $r.AppendChild($conds) | Out-Null
    $col.AppendChild($r) | Out-Null
}

function Add-ExactPathRule($doc, $col, [string]$path, [string]$name) {
    $r = $doc.CreateElement('FilePathRule')
    $r.SetAttribute('Id', [guid]::NewGuid().ToString())
    $r.SetAttribute('Name', 'NetGuard path: ' + $name)
    $r.SetAttribute('Description', 'NetGuard: ' + $name)
    $r.SetAttribute('UserOrGroupSid', 'S-1-1-0')
    $r.SetAttribute('Action', 'Allow')
    $conds = $doc.CreateElement('Conditions')
    $c = $doc.CreateElement('FilePathCondition')
    $c.SetAttribute('Path', $path)
    $conds.AppendChild($c) | Out-Null
    $r.AppendChild($conds) | Out-Null
    $col.AppendChild($r) | Out-Null
}

function Reset-AppLockerCache {
    # 本机实测：Set-AppLockerPolicy 只写注册表，AppIDSvc 仍用旧的
    # C:\Windows\System32\AppLocker\Exe.AppLocker 缓存；必须删缓存并重启服务，
    # 新策略才会真正加载（否则表现为“策略已应用但完全不拦”）。
    try {
        & sc.exe stop AppIDSvc 2>&1 | Out-Null
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep 1
            if ((Get-Service AppIDSvc -ErrorAction SilentlyContinue).Status -eq 'Stopped') { break }
        }
        Remove-Item 'C:\Windows\System32\AppLocker\Exe.AppLocker' -Force -ErrorAction SilentlyContinue
        Remove-Item 'C:\Windows\System32\AppLocker\AppCache.dat*' -Force -ErrorAction SilentlyContinue
        & sc.exe start AppIDSvc 2>&1 | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep 1
            if ((Get-Service AppIDSvc -ErrorAction SilentlyContinue).Status -eq 'Running') { break }
        }
        Start-Sleep 2
        Say ('AppLocker 缓存已重建，AppIDSvc: ' + (Get-Service AppIDSvc -ErrorAction SilentlyContinue).Status)
    } catch {
        Warn ('重建 AppLocker 缓存失败: ' + $_.Exception.Message)
    }
}

function Enable-AppLocker($policy, [string[]]$extraFiles) {
    $cmd = Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue
    if (-not $cmd) { Warn '系统没有 AppLocker cmdlet，跳过 AppLocker 规则'; return $false }

    $orig = Get-AppLockerXml
    if ($null -eq $orig) { Warn '无法读取 AppLocker 策略，跳过'; return $false }

    # 只在第一次启用时备份原始策略；重复 Enable 不会覆盖备份
    if (-not (Test-Path $aclBackup)) {
        [IO.File]::WriteAllText($aclBackup, $orig, (New-Object Text.UTF8Encoding($false)))
        Say ('AppLocker 原始策略已备份: ' + $aclBackup)
    }

    [xml]$doc = $orig
    if (-not $doc.DocumentElement) { [xml]$doc = '<AppLockerPolicy Version="1" />' }
    $root = $doc.DocumentElement
    if ($root.Name -ne 'AppLockerPolicy') { throw 'AppLocker 策略根节点不是 AppLockerPolicy' }

    $col = $root.SelectSingleNode("RuleCollection[@Type='Exe']")
    if (-not $col) {
        $col = $doc.CreateElement('RuleCollection')
        $col.SetAttribute('Type', 'Exe')
        $col.SetAttribute('EnforcementMode', 'Enabled')
        $root.AppendChild($col) | Out-Null
        Say '创建 AppLocker EXE 规则集合'
    }
    $col.SetAttribute('EnforcementMode', 'Enabled')

    # 没有规则时补默认放行（Windows / Program Files），否则整机会被锁死
    $existing = $col.SelectNodes('FilePathRule|FileHashRule|FilePublisherRule')
    if ($existing.Count -eq 0) {
        Add-PathRule $doc $col '%WINDIR%\*' 'NetGuard default: Windows'
        Add-PathRule $doc $col '%PROGRAMFILES%\*' 'NetGuard default: Program Files'
        if (${env:ProgramFiles(x86)}) {
            Add-PathRule $doc $col '%PROGRAMFILES(X86)%\*' 'NetGuard default: Program Files (x86)'
        }
        Say '添加 AppLocker 默认路径规则（Windows / Program Files）'
    }

    # 清掉旧的 NetGuard 规则，保证幂等
    foreach ($n in @($col.SelectNodes("FileHashRule[starts-with(@Description,'NetGuard:')]"))) {
        $col.RemoveChild($n) | Out-Null
    }
    foreach ($n in @($col.SelectNodes("FilePathRule[starts-with(@Description,'NetGuard:')]"))) {
        $col.RemoveChild($n) | Out-Null
    }

    $added = 0
    $seen = @{}
    foreach ($p in $policy.Procs) {
        if (-not $p.Enabled -or $p.Path -eq '' -or $p.Path -eq '*') { continue }
        if ($p.Sha256 -notmatch '^[0-9A-F]{64}$') {
            Warn ('程序哈希无效，跳过 AppLocker 规则: ' + $p.Name + ' / ' + $p.Path)
            continue
        }
        if (-not (Test-Path $p.Path)) {
            Warn ('程序不存在，跳过 AppLocker 规则: ' + $p.Path)
            continue
        }
        # 只用精确路径规则：
        # 本机实测 Win10 22H2 本地策略里的 FileHashRule 会导致整个 Exe 集合
        # 不编译（表现为“策略已应用但完全不拦”），而 FilePathRule 正常。
        # 哈希原子性由可选的内核驱动提供；标准用户无法改写 ACL 保护的程序目录。
        Add-ExactPathRule $doc $col $p.Path $p.Name
        $seen[$p.Path.ToLowerInvariant()] = $true
        $added++
    }
    foreach ($f in $extraFiles) {
        if (-not (Test-Path $f)) { continue }
        if ($seen.ContainsKey($f.ToLowerInvariant())) { continue }
        Add-ExactPathRule $doc $col $f (Split-Path $f -Leaf)
        $seen[$f.ToLowerInvariant()] = $true
        $added++
    }

    $tmp = $aclApplied + '.tmp'
    $doc.Save($tmp)
    if ($DryRun) { Say ("[dry] apply AppLocker policy with {0} hash rule(s)" -f $added); return $true }

    Set-AppLockerPolicy -XmlPolicy $tmp -ErrorAction Stop
    Move-Item $tmp $aclApplied -Force
    Say ('AppLocker 策略已应用（程序规则 {0} 条）' -f $added)
    Reset-AppLockerCache
    return $true
}

function Restore-AppLocker($state) {
    if (-not $state.AppLocker -or -not $state.AppLocker.Applied) { return }
    if (-not (Test-Path $aclBackup)) { Warn 'AppLocker 备份不存在，无法还原'; return }
    if (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue) {
        try {
            Set-AppLockerPolicy -XmlPolicy $aclBackup -ErrorAction Stop
            Say 'AppLocker 策略已还原'
        } catch { Warn ('还原 AppLocker 失败: ' + $_.Exception.Message) }
    }
    if ($state.AppLocker.ServiceStartType) {
        try { Set-Service AppIDSvc -StartupType $state.AppLocker.ServiceStartType } catch { }
    }
    Reset-AppLockerCache
    if ($state.AppLocker.ServiceStatus -eq 'Stopped') {
        try { Stop-Service AppIDSvc -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Enable-FreeMode {
    $policy = Get-Policy
    if (-not $policy.DefaultDeny) {
        Warn '策略 DefaultDeny=0；免费模式不启用（否则会与策略意图冲突）'
        return 2
    }

    # 幂等：已有状态先还原，再按当前策略重建
    if (Test-Path $statePath) {
        Say '检测到已有免费模式状态，先还原再重建'
        Disable-FreeMode | Out-Null
    }

    $state = [ordered]@{
        Version      = 1
        AppliedAt    = (Get-Date -Format o)
        PolicyPath   = $PolicyPath
        Group        = $group
        Profiles     = @{}
        DisabledBuiltinRules = @()
        AppLocker    = @{ Applied = $false; ServiceStartType = ''; ServiceStatus = '' }
    }

    # 记录当前默认出站动作
    foreach ($p in @(Get-NetFirewallProfile -Profile Domain, Private, Public)) {
        $state.Profiles[$p.Name] = $p.DefaultOutboundAction.ToString()
    }
    if (-not $DryRun) {
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }

    Say '创建防火墙出站放行规则'
    Remove-FreeModeRules | Out-Null

    $index = 0
    foreach ($p in $policy.Procs) {
        if (-not $p.Enabled -or $p.Path -eq '') { continue }
        $targets = @()
        if ($p.Endpoint -eq '' -or $p.Endpoint -eq '*') {
            $targets = @($policy.Eps.Values | Where-Object { $_.Enabled })
        } else {
            foreach ($nm in $p.Endpoint.Split(',')) {
                $key = $nm.Trim().ToLowerInvariant()
                if ($policy.Eps.ContainsKey($key)) {
                    if ($policy.Eps[$key].Enabled) { $targets += $policy.Eps[$key] }
                } else {
                    Warn ('程序 {0} 绑定的地址 {1} 不存在' -f $p.Name, $nm)
                }
            }
        }
        foreach ($e in $targets) {
            $ports = @()
            foreach ($x in $e.Ports.Split(',')) { $x = $x.Trim(); if ($x -ne '') { $ports += $x } }
            if ($ports.Count -eq 0) { continue }
            $remote = @($e.Cidr)
            $protos = @()
            if ($e.Proto -eq '' -or $e.Proto -ieq 'ANY') { $protos = @('TCP', 'UDP') } else { $protos = @($e.Proto.ToUpperInvariant()) }
            foreach ($proto in $protos) {
                $index++
                $display = ('{0} -> {1} [{2} {3}]' -f $p.Name, $e.Name, $proto, ($ports -join ','))
                New-AllowRule -display $display -program $p.Path -remote $remote -ports $ports -proto $proto
            }
        }
    }

    if ($policy.AllowDhcp) {
        New-AllowRule -display 'DHCP' -program '' -remote $null -ports @('67') -proto 'UDP' -service 'Dhcp' -localPort @('68')
    }
    if ($policy.AllowDnsServer -ne '') {
        foreach ($dns in $policy.AllowDnsServer.Split(',')) {
            $dns = $dns.Trim()
            if ($dns -eq '') { continue }
            New-AllowRule -display ('DNS ' + $dns) -program '' -remote @($dns) -ports @('53') -proto 'UDP'
        }
    }
    if ($policy.LanAllow -ne '' -and $policy.LanAnyProc) {
        foreach ($lan in $policy.LanAllow.Split(',')) {
            $lan = $lan.Trim()
            if ($lan -eq '') { continue }
            New-AllowRule -display ('LAN ' + $lan) -program '' -remote @($lan) -ports $null -proto 'TCP'
            New-AllowRule -display ('LAN ' + $lan) -program '' -remote @($lan) -ports $null -proto 'UDP'
        }
    }

    # 关闭 Windows 自带出站放行规则（可选，默认关闭以形成严格白名单）
    if (-not $KeepBuiltinRules) {
        $builtin = @(Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled True -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -notlike 'NetGuard:*' -and ($_.Group -notcontains $group) })
        Say ('发现 {0} 条系统出站放行规则，准备关闭' -f $builtin.Count)
        $disabled = @()
        foreach ($r in $builtin) {
            if ($DryRun) { continue }
            try {
                Disable-NetFirewallRule -InputObject $r -ErrorAction Stop
                $disabled += $r.Name
            } catch { }
        }
        $state.DisabledBuiltinRules = $disabled
        if (-not $DryRun) {
            Say ('已关闭 {0} 条系统出站放行规则' -f $disabled.Count)
        }
    }

    # 最后切换默认出站动作，避免中间态断网
    if (-not $DryRun) {
        Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Block
        Say '防火墙默认出站动作已设为 Block'
    }

    # AppLocker 哈希规则（含 NetGuard 自身，避免管理工具被锁）
    if ($UseAppLocker) {
        $extra = @()
        $selfExe = Join-Path $PSScriptRoot 'NetGuard.exe'
        $selfUi = Join-Path $PSScriptRoot 'NetGuardUI.exe'
        if (Test-Path $selfExe) { $extra += $selfExe }
        if (Test-Path $selfUi) { $extra += $selfUi }
        $svcBefore = Get-Service AppIDSvc -ErrorAction SilentlyContinue
        if ($svcBefore) {
            $state.AppLocker.ServiceStartType = $svcBefore.StartType.ToString()
            $state.AppLocker.ServiceStatus = $svcBefore.Status.ToString()
        }
        try {
            $state.AppLocker.Applied = Enable-AppLocker $policy $extra
        } catch {
            Warn ('AppLocker 启用失败（防火墙仍生效）: ' + $_.Exception.Message)
            $state.AppLocker.Applied = $false
        }
    }

    if (-not $DryRun) {
        $state.AppliedAt = (Get-Date -Format o)
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }
    Say '免费模式已启用'
    return 0
}

function Disable-FreeMode {
    $state = $null
    if (Test-Path $statePath) {
        try { $state = Get-Content $statePath -Raw | ConvertFrom-Json } catch { Warn '状态文件损坏，按无状态清理' }
    } else {
        Say '未找到免费模式状态文件，仅清理可能残留的规则'
    }

    # 先恢复默认动作，再动规则，避免清理过程中断网
    if ($state -and $state.Profiles) {
        foreach ($name in @($state.Profiles.PSObject.Properties.Name)) {
            $action = [string]$state.Profiles.$name
            if ($action) {
                if ($DryRun) { Say ("[dry] restore {0} DefaultOutboundAction={1}" -f $name, $action) }
                else {
                    try { Set-NetFirewallProfile -Profile $name -DefaultOutboundAction $action; Say ("{0} 默认出站恢复为 {1}" -f $name, $action) }
                    catch { Warn ("恢复 {0} 默认出站失败: {1}" -f $name, $_.Exception.Message) }
                }
            }
        }
    } else {
        # 没有状态时采取最保守的恢复：默认放行
        if (-not $DryRun) {
            try { Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Allow; Say '默认出站已恢复为 Allow' } catch { }
        }
    }

    if ($state -and $state.DisabledBuiltinRules) {
        $n = 0
        foreach ($name in @($state.DisabledBuiltinRules)) {
            if ($DryRun) { continue }
            try { Enable-NetFirewallRule -Name $name -ErrorAction Stop; $n++ } catch { }
        }
        Say ('已重新启用 {0} 条系统出站规则' -f $n)
    }

    Remove-FreeModeRules | Out-Null

    if ($state) { Restore-AppLocker $state }

    if (-not $DryRun) {
        Remove-Item $statePath -Force -ErrorAction SilentlyContinue
    }
    Say '免费模式已关闭'
    return 0
}

function Show-Status {
    $rules = @(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue)
    Say ('防火墙规则: {0} 条' -f $rules.Count)
    foreach ($p in @(Get-NetFirewallProfile -Profile Domain, Private, Public)) {
        Say ('  {0}: DefaultOutboundAction={1}' -f $p.Name, $p.DefaultOutboundAction)
    }
    if (Test-Path $statePath) {
        Say '状态文件: 存在'
        try {
            $s = Get-Content $statePath -Raw | ConvertFrom-Json
            Say ('  启用时间: ' + $s.AppliedAt)
            Say ('  关闭的系统规则: ' + @($s.DisabledBuiltinRules).Count + ' 条')
            Say ('  AppLocker: ' + $s.AppLocker.Applied)
        } catch { }
    } else {
        Say '状态文件: 不存在（未启用）'
    }
    if (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
        try {
            $xml = Get-AppLockerPolicy -Effective -Xml
            $count = ([regex]::Matches([string]$xml, 'Description="NetGuard:')).Count
            Say ('AppLocker 生效的 NetGuard 程序规则: {0} 条' -f $count)
        } catch { }
    }
}

Assert-Admin
switch ($Action) {
    'Enable' { exit (Enable-FreeMode) }
    'Disable' { exit (Disable-FreeMode) }
    default { Show-Status; exit 0 }
}
