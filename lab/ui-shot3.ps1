$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\ui-shot3.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 用交互会话计划任务截图 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred
Invoke-Command -Session $s -ScriptBlock { Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1 }
Copy-Item 'C:srcNetGuarduildNetGuardUI.exe' -ToSession $s -Destination 'C:NetGuardNetGuardUI2.exe' -Force
L ('guest exe size = ' + (Invoke-Command -Session $s -ScriptBlock { (Get-Item 'C:NetGuardNetGuardUI2.exe').Length }))
L "新 UI 已投放"

$r = Invoke-Command -Session $s -ScriptBlock {
    Remove-Item 'C:\NetGuard\ui2.bmp' -ErrorAction SilentlyContinue
    # 以当前交互用户 + 最高权限运行（/it = 仅在用户登录时运行）
    $out1 = & schtasks.exe /create /tn NgUiShot /tr "'C:\NetGuard\NetGuardUI.exe' --screenshot C:\NetGuard\ui2.bmp" /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1
    "create: " + ($out1 -join ' ')
    $out2 = & schtasks.exe /run /tn NgUiShot 2>&1
    "run: " + ($out2 -join ' ')
    Start-Sleep 12
    "task state: " + ((& schtasks.exe /query /tn NgUiShot /fo LIST 2>&1) -join ' | ')
    if (Test-Path 'C:\NetGuard\ui2.bmp') { "bmp=" + (Get-Item 'C:\NetGuard\ui2.bmp').Length } else { "bmp 缺失" }
    "--- ng.log ---"
    Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 6
}
$r | ForEach-Object { L "  $_" }

try {
    Copy-Item -FromSession $s -Path 'C:\NetGuard\ui2.bmp' -Destination "$RepoRoot\lab\ui2.bmp" -Force
    L "已取回: $((Get-Item "$RepoRoot\lab\ui2.bmp").Length) 字节"
} catch { L "取回失败: $($_.Exception.Message)" }
Remove-PSSession $s
L "完成"
