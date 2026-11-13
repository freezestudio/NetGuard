# NetGuard 卸载脚本 —— 需管理员（会先撤销过滤规则再删服务，避免留下"断网"状态）
$ErrorActionPreference = 'Continue'
$data = Join-Path $env:ProgramData 'NetGuard'
$svc  = 'NetGuard'
function Say($m) { Write-Host "[*] $m" }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '需要以管理员身份运行'
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $here 'NetGuard.exe'

# 卸载中途失败也要尽量把免费模式关掉，避免留下“默认阻止出站 + 规则不全”的机器
trap {
    Write-Host "[x] 卸载中断: $($_.Exception.Message)"
    $fmTrap = Join-Path $here 'free-mode.ps1'
    if (-not (Test-Path $fmTrap)) { $fmTrap = 'C:\NetGuard\free-mode.ps1' }
    if (Test-Path $fmTrap) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fmTrap -Action Disable | Out-Null
    }
    exit 1
}

# 1) 先等服务进入可用状态（刚安装时服务可能还在启动自检，IPC 尚未就绪）
$existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
if ($existing) {
    Say '等待服务进入可用状态（最多 30 秒）'
    for ($i = 0; $i -lt 30; $i++) {
        $existing.Refresh()
        if ($existing.Status -eq 'Running' -or $existing.Status -eq 'Stopped') { break }
        Start-Sleep 1
    }
    Say "服务状态: $($existing.Status)"

    # 2) 回滚并确认结果；失败时重试（服务可能刚启动 IPC）
    if (Test-Path $exe) {
        $rolled = $false
        for ($i = 0; $i -lt 5; $i++) {
            Say "通知服务回滚过滤规则（第 $($i + 1) 次）"
            $out = & $exe ctl rollback 2>&1
            $out | ForEach-Object { Write-Host "    $_" }
            if (($out -join "`n") -match 'OK') { $rolled = $true; break }
            Start-Sleep 2
        }
        if (-not $rolled) {
            Say 'ctl rollback 未确认成功；继续停止服务（会话级过滤器随进程退出消失）'
        }
    }

    # 3) 停止并等待真正 Stopped
    Say '停止服务'
    & sc.exe stop $svc | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        $existing.Refresh()
        if ($existing.Status -eq 'Stopped') { break }
        Start-Sleep 1
    }
    Say "停止后状态: $($existing.Status)"
}

# 4) 删除服务，并清理可能残留（已从 SCM 删除但进程仍持有会话过滤器）
Say '删除服务'
& sc.exe delete $svc | Out-Null
Start-Sleep 2

$left = Get-Process NetGuard -ErrorAction SilentlyContinue
if ($left) {
    Say "清理残留 NetGuard 进程: $($left.Id -join ',')"
    $left | Stop-Process -Force
    Start-Sleep 2
}

# 3) 清理旧版本遗留的持久化过滤器：服务已停，会话级过滤器已随进程消失，
#    但老版本创建过的 persistent 过滤器会跨重启继续断网，这里一并清掉。
if (Test-Path $exe) {
    Say '清理旧版本遗留的 WFP 过滤器（persistent）'
    & $exe purge | ForEach-Object { Write-Host "    $_" }
}

# 4) 停止/删除 WFP callout 驱动
if (Get-Service -Name ngdrv -ErrorAction SilentlyContinue) {
    Say '停止/删除 WFP callout 驱动 ngdrv'
    & sc.exe stop ngdrv | Out-Null
    Start-Sleep 2
    & sc.exe delete ngdrv | Out-Null
    Start-Sleep 1
}

# 5) 关闭免费模式（防火墙/AppLocker）。放在最后：
#    - 之前 ctl rollback / purge 还需要执行 C:\NetGuard\NetGuard.exe，
#      而 AppLocker 只放行它的哈希；提前还原会把它自己锁在外面。
#    - 这里恢复默认出站动作、重新启用系统规则、还原 AppLocker。
$fm = Join-Path $here 'free-mode.ps1'
if (-not (Test-Path $fm)) { $fm = 'C:\NetGuard\free-mode.ps1' }
if (Test-Path $fm) {
    Say '关闭免费模式（防火墙/AppLocker）'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fm -Action Disable
    if ($LASTEXITCODE -ne 0) { Say "[!] 免费模式关闭返回 $LASTEXITCODE，请检查 $env:ProgramData\NetGuard\freemode.log" }
} else {
    $state = Join-Path $env:ProgramData 'NetGuard\freemode-state.json'
    if (Test-Path $state) {
        Say '[!] 未找到 free-mode.ps1，但检测到免费模式状态；尝试最小化恢复'
        try {
            Remove-NetFirewallRule -Group 'NetGuard-FreeMode' -ErrorAction SilentlyContinue
            Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Allow -ErrorAction SilentlyContinue
            Say '已删除 NetGuard 防火墙规则并把默认出站恢复为 Allow（系统自带规则需手工确认）'
        } catch { Say ('[!] 自动恢复失败: ' + $_.Exception.Message) }
    }
}
Say '免费模式检查完成'
Say '完成。策略文件保留在 %ProgramData%\NetGuard（如不再需要可手工删除）'
Say '部署密钥保留在 HKLM\SOFTWARE\NetGuard\PolicyKey（重装后旧策略仍可验证；删除该键即轮换）'
