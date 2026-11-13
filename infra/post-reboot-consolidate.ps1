# 重启后一次性整理：确保 C:\src\NetGuard 指向整合后的仓库
# 由 HKCU\...\RunOnce 调用，普通用户权限即可（junction 不需要管理员）。
$ErrorActionPreference = 'Continue'
$repo = 'C:\Users\freez\source\repo'
$log = Join-Path $repo 'infra\post-reboot.log'
function L([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
}
New-Item -ItemType Directory -Path (Split-Path $log -Parent) -Force | Out-Null
L '=== post-reboot consolidate start ==='

# 1) C:\VMs 联接（正常情况下已存在）
$vmsTarget = Join-Path $repo 'infra\vms'
if (Test-Path 'C:\VMs') {
    $item = Get-Item 'C:\VMs' -Force
    if ($item.LinkType -eq 'Junction') {
        L ('C:\VMs junction -> ' + ($item.Target -join ','))
    } else {
        L 'C:\VMs 存在但不是 junction，跳过（避免误删数据）'
    }
} elseif (Test-Path $vmsTarget) {
    & cmd.exe /c ('mklink /J "C:\VMs" "' + $vmsTarget + '"') 2>&1 | ForEach-Object { L ('  ' + $_) }
    L 'created C:\VMs junction'
}

# 2) C:\src\NetGuard -> repo
$old = 'C:\src\NetGuard'
$made = $false
for ($i = 0; $i -lt 40; $i++) {
    if ((Test-Path $old) -and -not ((Get-Item $old -Force).LinkType -eq 'Junction')) {
        $children = @(Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            & cmd.exe /c ('rmdir "' + $old + '"') 2>&1 | ForEach-Object { }
        } else {
            L ('C:\src\NetGuard 非空，保留不动（' + $children.Count + ' 项）')
            break
        }
    }
    if (-not (Test-Path $old)) {
        & cmd.exe /c ('mklink /J "' + $old + '" "' + $repo + '"') 2>&1 | ForEach-Object { L ('  ' + $_) }
    }
    if ((Test-Path $old) -and ((Get-Item $old -Force).LinkType -eq 'Junction')) {
        $made = $true
        break
    }
    Start-Sleep 5
}
L ('C:\src\NetGuard junction created=' + $made)

# 3) 状态记录
try {
    $last = & git -C $repo log --oneline -1 2>&1
    L ('git: ' + ($last -join ' '))
    $st = & git -C $repo status --porcelain 2>&1
    L ('git status lines: ' + @($st).Count)
} catch { L ('git check failed: ' + $_.Exception.Message) }

L '=== post-reboot consolidate done ==='
