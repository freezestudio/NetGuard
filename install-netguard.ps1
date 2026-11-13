# NetGuard 安装脚本（静默、幂等）—— 需管理员
# 用法:  powershell -ExecutionPolicy Bypass -File install-netguard.ps1 [-InstallDriver] [-FreeMode]
#   -InstallDriver：同时安装/启动 WFP callout 驱动 drv\ngdrv.sys（必须已签名）
#   -FreeMode：启用免费模式（Windows 防火墙出站白名单，无需驱动/证书）
#   -FreeModeAppLocker：免费模式额外启用 AppLocker 精确路径规则（实验性）
#   -FreeModeKeepBuiltin：免费模式保留 Windows 自带出站放行规则（默认关闭，更严格）
param(
    [switch]$InstallDriver,
    [switch]$FreeMode,
    [switch]$FreeModeAppLocker,
    [switch]$FreeModeKeepBuiltin
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$data = Join-Path $env:ProgramData 'NetGuard'
$policy = Join-Path $data 'policy.ini'
$exe  = Join-Path $here 'NetGuard.exe'
$ui   = Join-Path $here 'NetGuardUI.exe'
$svc  = 'NetGuard'

function Say($m) { Write-Host "[*] $m" }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '需要以管理员身份运行'
}

$transcripting = $false
function Stop-InstallLog {
    if ($script:transcripting) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:transcripting = $false
    }
}

# 任何中途失败：尽量把服务重新拉起，并留下 install.log，避免停在“服务已删但未装好”的状态
trap {
    Write-Host "[x] 安装失败: $($_.Exception.Message)"
    try {
        if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
            if (Test-Path $exe) { & $exe install | Out-Null }
        }
        & sc.exe start $svc | Out-Null
    } catch { }
    Stop-InstallLog
    exit 1
}

if (-not (Test-Path $exe)) { throw "未找到 $exe（请把整个部署目录一起拷贝到目标机）" }
if (-not (Test-Path $ui))  { Write-Host "[!] 未找到 $ui（命令行部分仍可安装）" }

# 1) 数据目录：先收紧 ACL，再做策略/密钥校验；这样即使安装失败，普通用户也不能写
Say "检查部署目录: $here"
New-Item -ItemType Directory -Path $data -Force | Out-Null
Say "加固策略目录 ACL"
& icacls $data /inheritance:r | Out-Null
if ($LASTEXITCODE -ne 0) { throw '加固策略目录 ACL 失败（inheritance）' }
& icacls $data /grant "*S-1-5-18:(OI)(CI)F" | Out-Null          # SYSTEM
if ($LASTEXITCODE -ne 0) { throw '加固策略目录 ACL 失败（SYSTEM）' }
& icacls $data /grant "*S-1-5-32-544:(OI)(CI)F" | Out-Null      # Administrators
if ($LASTEXITCODE -ne 0) { throw '加固策略目录 ACL 失败（Administrators）' }
& icacls $data /grant "*S-1-5-32-545:(OI)(CI)RX" | Out-Null     # Users 只读
if ($LASTEXITCODE -ne 0) { throw '加固策略目录 ACL 失败（Users）' }

# 目录里已存在的文件（升级/预置策略）也要去掉旧继承，否则旧 ACL 会保留
Get-ChildItem -Path $data -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
    & icacls $_.FullName /inheritance:r | Out-Null
    & icacls $_.FullName /grant "*S-1-5-18:F" | Out-Null
    & icacls $_.FullName /grant "*S-1-5-32-544:F" | Out-Null
    & icacls $_.FullName /grant "*S-1-5-32-545:RX" | Out-Null
}

# 1.5) 程序目录：普通用户只读，防止替换白名单 exe（P0 加固）
$prog = $here
Say "加固程序目录 ACL: $prog"
& icacls $prog /inheritance:r | Out-Null
if ($LASTEXITCODE -ne 0) { throw '加固程序目录 ACL 失败（inheritance）' }
& icacls $prog /grant "*S-1-5-18:(OI)(CI)F" | Out-Null          # SYSTEM
& icacls $prog /grant "*S-1-5-32-544:(OI)(CI)F" | Out-Null      # Administrators
& icacls $prog /grant "*S-1-5-32-545:(OI)(CI)RX" | Out-Null     # Users 只读/执行
# 已存在的 exe/dll/脚本也去掉旧继承，避免单个文件仍可被普通用户改写
Get-ChildItem -Path $prog -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
    & icacls $_.FullName /inheritance:r | Out-Null
    & icacls $_.FullName /grant "*S-1-5-18:F" | Out-Null
    & icacls $_.FullName /grant "*S-1-5-32-544:F" | Out-Null
    & icacls $_.FullName /grant "*S-1-5-32-545:RX" | Out-Null
}

# admin.dat 含口令盐与哈希，不能给 Users 读
$adminDat = Join-Path $data 'admin.dat'
if (Test-Path $adminDat) {
    Say "收紧 admin.dat 权限（仅 SYSTEM / Administrators）"
    & icacls $adminDat /inheritance:r | Out-Null
    & icacls $adminDat /grant "*S-1-5-18:F" | Out-Null
    & icacls $adminDat /grant "*S-1-5-32-544:F" | Out-Null
}

try {
    Start-Transcript -Path (Join-Path $data 'install.log') -Append | Out-Null
    $transcripting = $true
} catch {
    Write-Host "[!] 无法启用安装日志（继续安装）"
}
Say "准备部署密钥（HKLM\SOFTWARE\NetGuard，仅 SYSTEM/Administrators 可读写）"
& $exe initkey | Out-Host
if ($LASTEXITCODE -ne 0) { throw '初始化部署密钥失败（install.log 中有详细原因）' }

if (-not (Test-Path $policy)) {
    & $exe initpolicy | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $policy)) { throw '生成示例策略失败' }
    Say "已生成示例策略（请用 NetGuardUI 修改后保存）"
}

Say "校验策略签名与格式（fail-closed：无签名/签名无效将被拒绝）"
& $exe verify | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw '现有策略未通过校验（签名/密钥/格式）。请用 NetGuardUI 重新保存；或确认内容后运行 NetGuard.exe sign 迁移到本机密钥，再重新安装。'
}

# 2) 停旧服务（幂等）
$existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
if ($existing) {
    Say "停止并删除已存在的服务"
    & sc.exe stop $svc | Out-Null
    Start-Sleep 3
    & sc.exe delete $svc | Out-Null
    Start-Sleep 2
}

# 2.5) 清理旧版本遗留的持久化过滤器（旧版本可能用 FWPM_FILTER_FLAG_PERSISTENT 下发，
#      服务停止后仍会断网；这里统一按 provider 清一遍，失败不阻断安装）
Say "清理旧版本遗留的 WFP 过滤器"
& $exe purge | Out-Host

# 3) 安装服务（自动启动，LocalSystem）
Say "安装服务"
& $exe install | Out-Null
if ($LASTEXITCODE -ne 0) { throw '安装服务失败' }

# 4) 服务 DACL 加固：仅 SYSTEM 与 Administrators 可完全控制（普通用户不能启停/改配置）
Say "加固服务 DACL（仅 SYSTEM / Administrators）"
$sddl = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)'
& sc.exe sdset $svc $sddl | Out-Null

# 5) 崩溃自动重启（3 次，逐次拉长）
Say "配置失败自动重启"
& sc.exe failure $svc reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null

# 6) 启动
Say "启动服务"
& sc.exe start $svc | Out-Null
Start-Sleep 5
$st = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status
Say "服务状态: $st"

# 6.5) 可选：安装 WFP callout 驱动（完整路径 + 连接时哈希门禁）
if ($InstallDriver) {
    $drvSys = Join-Path $here 'drv\ngdrv.sys'
    if (-not (Test-Path $drvSys)) {
        Say "[!] 未找到 $drvSys；跳过驱动安装（仍使用用户态管控）"
    } else {
        Say "安装 WFP callout 驱动: $drvSys"
        & sc.exe stop ngdrv 2>&1 | Out-Null
        & sc.exe delete ngdrv 2>&1 | Out-Null
        Start-Sleep 1
        & sc.exe create ngdrv type= kernel start= auto binPath= ('"' + $drvSys + '"') | Out-Null
        & sc.exe start ngdrv | Out-Null
        Start-Sleep 2
        $drvSt = (Get-Service -Name ngdrv -ErrorAction SilentlyContinue).Status
        Say "驱动状态: $drvSt"
        if ($drvSt -ne 'Running') {
            Say "[!] 驱动未运行（签名/testsigning/兼容性？）；用户态管控仍继续工作"
        } else {
            # 服务可能先于驱动启动，启动时的 whitelist 下发会失败；这里强制重发一次。
            Say "同步驱动白名单（ctl apply）"
            for ($i = 0; $i -lt 5; $i++) {
                $o = & $exe ctl apply 2>&1
                if (($o -join "`n") -match 'OK') { break }
                Start-Sleep 2
            }
        }
    }
}

# 7) 可选：免费模式（无需驱动/证书）
#    Windows 防火墙出站默认阻止 + 按策略放行；AppLocker 按 SHA-256 放行程序。
#    任何一步失败都要回滚，避免把机器留在“防火墙已 Block、规则没建全”的状态。
if ($FreeMode) {
    $fm = Join-Path $here 'free-mode.ps1'
    if (-not (Test-Path $fm)) {
        Say "[!] 未找到 $fm；跳过免费模式（仍使用用户态管控）"
    } else {
        Say '启用免费模式（防火墙出站白名单）'
        $fmArgs = @('-Action', 'Enable')
        if ($FreeModeAppLocker) { $fmArgs += '-UseAppLocker' }
        if ($FreeModeKeepBuiltin) { $fmArgs += '-KeepBuiltinRules' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fm @fmArgs
        $fmExit = $LASTEXITCODE
        if ($fmExit -ne 0) {
            Say "[x] 免费模式启用失败（exit=$fmExit），回滚防火墙/AppLocker"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fm -Action Disable | Out-Null
            throw '启用免费模式失败（已回滚）'
        }
    }
}

# 8) 自检摘要
if (Test-Path (Join-Path $data 'audit.log')) {
    Say "最近审计记录："
    Get-Content (Join-Path $data 'audit.log') | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
}
Say "安装日志: $(Join-Path $data 'install.log')"
Stop-InstallLog
Say '完成。管理界面：NetGuardUI.exe；命令行：NetGuard.exe ctl status'
