$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
. "$RepoRoot\lab\ng-lab-common.ps1"
$log = "$RepoRoot\lab\installer-test.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 安装包 + DACL 加固验证 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

# 1) 投放安装脚本与程序
Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 2
    & sc.exe delete NetGuard 2>&1 | Out-Null
    Start-Sleep 1
    Get-Process NetGuard -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null
}
Copy-Item "$RepoRoot\build\NetGuard.exe"   -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item "$RepoRoot\build\NetGuardUI.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
Copy-Item "$RepoRoot\install-netguard.ps1" -ToSession $s -Destination 'C:\NetGuard\install-netguard.ps1' -Force
Copy-Item "$RepoRoot\uninstall-netguard.ps1" -ToSession $s -Destination 'C:\NetGuard\uninstall-netguard.ps1' -Force
L "文件已投放"

# 1.5) 准备已签名策略（安装脚本会 verify；旧夹具无签名会中止）
$prep = Invoke-Command -Session $s -ScriptBlock {
    if (Test-Path 'C:\ProgramData\NetGuard\policy.ini') {
        & 'C:\NetGuard\NetGuard.exe' sign 2>&1
    } else {
        & 'C:\NetGuard\NetGuard.exe' initpolicy 2>&1
    }
    "prepare exit=$LASTEXITCODE"
}
$prep | ForEach-Object { L "  $_" }

# 2) 跑安装脚本
$r = Invoke-Command -Session $s -ScriptBlock {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\install-netguard.ps1' 2>&1
}
$r | ForEach-Object { L "  $_" }

# 3) 验证 DACL / 失败动作 / 服务状态
$v = Invoke-Command -Session $s -ScriptBlock {
    "--- service sd ---"
    (& sc.exe sdshow NetGuard) -join ''
    "--- failure actions ---"
    (& sc.exe qfailure NetGuard) -join "`n"
    "--- data dir acl ---"
    (Get-Acl 'C:\ProgramData\NetGuard').Access | ForEach-Object { "  $($_.IdentityReference) $($_.FileSystemRights)" }
    "--- state ---"
    (Get-Service NetGuard).Status
    "--- ctl status ---"
    (& cmd.exe /c 'C:\NetGuard\NetGuard.exe ctl status' 2>&1) -join ' / '
}
$v | ForEach-Object { L "  $_" }

# 4) 普通用户权限：只检查 SDDL，不能用管理员会话真的 sc stop（会停掉待测服务）
$sd = Invoke-Command -Session $s -ScriptBlock { (& sc.exe sdshow NetGuard) -join '' }
L "  service sddl: $sd"
L "  （PS Direct 会话为管理员；普通用户权限由 SDDL 保证，未执行实际停服务）"

# 5) 卸载验证
$u = Invoke-Command -Session $s -ScriptBlock {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\uninstall-netguard.ps1' 2>&1
    Start-Sleep 2
    "service exists after uninstall: " + [bool](Get-Service NetGuard -ErrorAction SilentlyContinue)
    "process exists after uninstall: " + [bool](Get-Process NetGuard -ErrorAction SilentlyContinue)
    $f = 'C:\ProgramData\NetGuard\filters.txt'
    if (Test-Path $f) { "filters.txt lines after uninstall: " + (Get-Content $f | Measure-Object).Count }
    else { "filters.txt after uninstall: missing" }
}
$u | ForEach-Object { L "  $_" }

Remove-PSSession $s
L "完成"
