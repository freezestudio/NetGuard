$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
. "$RepoRoot\lab\ng-lab-common.ps1"
$log = "$RepoRoot\lab\test-win10b.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win10 验证 v2 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$sec = ConvertTo-SecureString '1' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('freeze', $sec)

try { $s = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop }
catch { L "PS Direct 失败: $($_.Exception.Message)"; exit 1 }

Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 1
    & sc.exe delete NetGuard 2>&1 | Out-Null
    Get-Process NetGuard -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    New-Item -ItemType Directory -Path 'C:\NetGuard','C:\ProgramData\NetGuard' -Force | Out-Null
}
Copy-Item "$RepoRoot\build\NetGuard.exe" -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item "$RepoRoot\lab\policy-win10.ini" -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
Sign-NgGuestPolicy -Session $s | ForEach-Object { L "  $_" }
L '已重新投放 exe + policy'

# 1) 会话权限
$info = Invoke-Command -Session $s -ScriptBlock {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    [pscustomobject]@{
        User      = $id.Name
        IsAdmin   = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Integrity = ($id.Groups | Where-Object { $_.Value -match '^S-1-16-' } | Select-Object -First 1).Value
    }
}
L "会话身份: $($info.User)  IsAdmin=$($info.IsAdmin)  Integrity=$($info.Integrity)"

# 2) 逐条执行，输出写文件再读回（UTF-8）
function RunStep($desc, $exeArgs) {
    L "--- $desc ---"
    $script = @'
param($args0)
$env:PYTHONIOENCODING='utf-8'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$outFile = 'C:\NetGuard\step-out.txt'
Remove-Item $outFile -ErrorAction SilentlyContinue
& cmd.exe /c "C:\NetGuard\NetGuard.exe $args0 > C:\NetGuard\step-out.txt 2>&1"
"exit=$LASTEXITCODE"
if (Test-Path $outFile) { Get-Content $outFile -Encoding Default 2>$null }
'@
    try {
        $r = Invoke-Command -Session $s -ScriptBlock ([scriptblock]::Create($script)) -ArgumentList $exeArgs
        $r | ForEach-Object { L "  $_" }
    } catch { L "  异常: $($_.Exception.Message)" }
}

RunStep 'selftest（基线）' 'selftest'
RunStep 'apply' 'apply'
RunStep 'selftest（应用后）' 'selftest'
RunStep 'status' 'status'
RunStep 'rollback' 'rollback'
RunStep 'selftest（回滚后）' 'selftest'

Remove-PSSession $s
L "完成"
