$RepoRoot = Split-Path $PSScriptRoot -Parent
# 给 Win10-Pro-22H2 配置开机自动登录（freeze / 1），并重启验证。
# 用法（宿主普通权限即可，PowerShell Direct 需要本地管理员）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File lab\fix-win10-autologon.ps1
#
# 注意：本机 Microsoft.PowerShell.Security 模块的 TypeData 有冲突，
# ConvertTo-SecureString 无法自动加载，所以这里手工构造 SecureString。

$ErrorActionPreference = 'Stop'
$vm = 'Win10-Pro-22H2'
$log = "$RepoRoot\lab\fix-win10-autologon.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== fix autologon $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)

if ((Get-VM -Name $vm).State -ne 'Running') {
    Start-VM -Name $vm
    for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Seconds 2; try { $null = New-PSSession -VMName $vm -Credential $cred -ErrorAction Stop; break } catch {} }
}

$s = New-PSSession -VMName $vm -Credential $cred
$r = Invoke-Command -Session $s -ScriptBlock {
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $wl -Name AutoAdminLogon  -Value '1' -Type String
    Set-ItemProperty -Path $wl -Name DefaultUserName -Value 'freeze' -Type String
    Set-ItemProperty -Path $wl -Name DefaultPassword -Value '1' -Type String
    Set-ItemProperty -Path $wl -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
    Remove-ItemProperty -Path $wl -Name AutoLogonCount -ErrorAction SilentlyContinue

    # 自动登录后不要停在锁屏
    $persPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
    if (-not (Test-Path $persPath)) { New-Item -Path $persPath -Force | Out-Null }
    Set-ItemProperty -Path $persPath -Name NoLockScreen -Value 1 -Type DWord

    # 登录界面不要求 Ctrl+Alt+Del
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name DisableCAD -Value 1 -Type DWord

    # 关休眠/快速启动，保证每次都是真正的冷启动
    powercfg.exe /hibernate off | Out-Null

    Get-ItemProperty $wl | Select-Object AutoAdminLogon, DefaultUserName, DefaultDomainName, DefaultPassword |
        Format-List | Out-String
}
$r | ForEach-Object { L "$_" }
Remove-PSSession $s

# 重启验证：必须能在无人值守的情况下出现 freeze 的 console 会话 + explorer
L 'rebooting to verify'
$s = New-PSSession -VMName $vm -Credential $cred
Invoke-Command -Session $s -ScriptBlock { shutdown.exe /r /t 0 /f }
Remove-PSSession $s

$ok = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 10
    try {
        $s = New-PSSession -VMName $vm -Credential $cred -ErrorAction Stop
        $r = Invoke-Command -Session $s -ScriptBlock {
            "boot=$((Get-CimInstance Win32_OperatingSystem).LastBootUpTime)"
            (query.exe user 2>&1 | Out-String)
        }
        Remove-PSSession $s
        $text = ($r -join "`n")
        L ("t+{0}s  {1}" -f (($i + 1) * 10), ($text -replace "`r?`n", ' | '))
        if ($text -match 'freeze' -and $text -match 'console') { $ok = $true; break }
    } catch {
        L ("t+{0}s  waiting: {1}" -f (($i + 1) * 10), $_.Exception.Message.Split("`n")[0])
    }
}
L $(if ($ok) { 'AUTOLOGON OK' } else { 'AUTOLOGON NOT CONFIRMED' })
