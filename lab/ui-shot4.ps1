$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\ui-shot4.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 交互会话截图 v4 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName   = 'Win10-Pro-22H2'
$hostExe  = "$RepoRoot\build\NetGuardUI.exe"
$guestExe = 'C:\NetGuard\NGUI_test.exe'
$guestBmp = 'C:\NetGuard\ui3.bmp'
$hostBmp  = "$RepoRoot\lab\ui3.bmp"

$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

# 1) 杀掉旧实例，用新文件名投放
Invoke-Command -Session $s -ScriptBlock {
    Get-Process NetGuardUI, NGUI_test -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item 'C:\NetGuard\NGUI_test.exe', 'C:\NetGuard\ui3.bmp' -ErrorAction SilentlyContinue
    Start-Sleep 1
}
Copy-Item $hostExe -ToSession $s -Destination $guestExe -Force
$size = Invoke-Command -Session $s -ScriptBlock { param($p) (Get-Item $p).Length } -ArgumentList $guestExe
L "投放完成，客户机内文件大小 = $size（宿主机为 $((Get-Item $hostExe).Length)）"

# 2) 建交互会话任务并运行
$r = Invoke-Command -Session $s -ScriptBlock {
    param($exe, $bmp)
    & schtasks.exe /delete /tn NgUiShot /f 2>&1 | Out-Null
    $tr = "`"$exe`" --screenshot $bmp"
    $o1 = & schtasks.exe /create /tn NgUiShot /tr $tr /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1
    $o2 = & schtasks.exe /run /tn NgUiShot 2>&1
    Start-Sleep 14
    "create=" + ($o1 -join ' ')
    "run=" + ($o2 -join ' ')
    if (Test-Path $bmp) { "bmp=" + (Get-Item $bmp).Length } else { "bmp 缺失" }
    "--- ng.log ---"
    Get-Content 'C:\ProgramData\NetGuard\ng.log' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 4
} -ArgumentList $guestExe, $guestBmp
$r | ForEach-Object { L "  $_" }

# 3) 取回
try {
    Copy-Item -FromSession $s -Path $guestBmp -Destination $hostBmp -Force
    L "已取回: $((Get-Item $hostBmp).Length) 字节"
} catch { L "取回失败: $($_.Exception.Message)" }
Remove-PSSession $s
L "完成"
