$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\ui-shot.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 界面截图验收 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item 'C:\NetGuard\ui.bmp' -ErrorAction SilentlyContinue
    Remove-Item 'C:\ProgramData\NetGuard\ui-selftest.txt' -ErrorAction SilentlyContinue
}
Copy-Item "$RepoRoot\build\NetGuardUI.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
L "新 UI 已投放"

$r = Invoke-Command -Session $s -ScriptBlock {
    $p = Start-Process -FilePath 'C:\NetGuard\NetGuardUI.exe' -ArgumentList '--screenshot','C:\NetGuard\ui.bmp' -PassThru -Wait
    "exit=$($p.ExitCode)"
    if (Test-Path 'C:\NetGuard\ui.bmp') { "bmp=" + (Get-Item 'C:\NetGuard\ui.bmp').Length + " bytes" } else { "bmp 缺失" }
    if (Test-Path 'C:\ProgramData\NetGuard\ui-selftest.txt') { Get-Content 'C:\ProgramData\NetGuard\ui-selftest.txt' -Encoding UTF8 }
    "--- ng.log ---"
    Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 5
}
$r | ForEach-Object { L "  $_" }

# 取回截图
try {
    Copy-Item -FromSession $s -Path 'C:\NetGuard\ui.bmp' -Destination "$RepoRoot\lab\ui-shot.bmp" -Force
    L "已取回: $((Get-Item "$RepoRoot\lab\ui-shot.bmp").Length) 字节"
} catch { L "取回失败: $($_.Exception.Message)" }

Remove-PSSession $s
L "完成"
