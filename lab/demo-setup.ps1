$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
. "$RepoRoot\lab\ng-lab-common.ps1"
$log = "$RepoRoot\lab\demo-setup.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 准备演示环境 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$exe    = "$RepoRoot\build\NetGuard.exe"
$ui     = "$RepoRoot\build\NetGuardUI.exe"
$adm    = "$RepoRoot\lab\admin.dat"
$inst   = "$RepoRoot\install-netguard.ps1"

# 示例策略（用记事本当"业务程序"，方便现场演示；哈希留空表示暂不锁定）
$policy = "[general]`r`nDefaultDeny=1`r`nAllowDhcp=1`r`nAllowLoopback=1`r`nTempAllowUntil=0`r`n`r`n" +
          "; 业务地址：医保前置`r`n" +
          "[ep.1]`r`nName=医保前置`r`nCidr=10.10.10.10/32`r`nPorts=8000-8005`r`nProto=TCP`r`nEnable=1`r`n`r`n" +
          "; 业务地址：门店打印机`r`n" +
          "[ep.2]`r`nName=门店打印机`r`nCidr=192.168.1.50/32`r`nPorts=9100`r`nProto=TCP`r`nEnable=1`r`n`r`n" +
          "; 业务程序：只有它才能访问上面这些地址`r`n" +
          "[proc.1]`r`nName=医保客户端(演示用记事本)`r`nPath=C:\Windows\System32\notepad.exe`r`nSha256=`r`nEndpoint=医保前置`r`nEnable=1`r`n"
$polFile = "$RepoRoot\lab\policy-demo.ini"
[IO.File]::WriteAllText($polFile, $policy, (New-Object Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- Windows 10
$w10 = 'Win10-Pro-22H2'
if ((Get-VM -Name $w10).State -ne 'Running') { Start-VM -Name $w10; Start-Sleep 40 }
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $w10 -Credential $cred

Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 2
    & sc.exe delete NetGuard 2>&1 | Out-Null
    Start-Sleep 1
    Get-Process NetGuard, NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Path 'C:\NetGuard','C:\ProgramData\NetGuard' -Force | Out-Null
}
Copy-Item $exe  -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item $ui   -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
Copy-Item $inst -ToSession $s -Destination 'C:\NetGuard\install-netguard.ps1' -Force
Copy-Item $adm  -ToSession $s -Destination 'C:\ProgramData\NetGuard\admin.dat' -Force
Copy-Item $polFile -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
Sign-NgGuestPolicy -Session $s | ForEach-Object { L "[Win10]   $_" }
L "[Win10] 文件已投放（含示例策略与管理员口令）"

$r = Invoke-Command -Session $s -ScriptBlock {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\install-netguard.ps1' 2>&1 | Select-Object -Last 6
    Start-Sleep 2
    (& cmd.exe /c 'C:\NetGuard\NetGuard.exe ctl status' 2>&1) -join ' / '
}
$r | ForEach-Object { L "  $_" }
Remove-PSSession $s

# ---------------------------------------------------------------- Windows 7
$w7 = 'Win7-Pro-x64'
$v7 = Get-VM -Name $w7
if ($v7.State -ne 'Off') { Stop-VM -Name $w7 -TurnOff -Force; Start-Sleep 8 }
$vhd = "$VmsRoot\$w7\disk.vhdx"
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null
Copy-Item $exe $ng\NetGuard.exe -Force
Copy-Item $ui  $ng\NetGuardUI.exe -Force
Copy-Item $inst $ng\install-netguard.ps1 -Force
Copy-Item $adm $pd\admin.dat -Force
if (-not (Test-Path "$pd\policy.ini")) { Copy-Item $polFile "$pd\policy.ini" -Force }
$w7Key = New-NgPolicyKey
Sign-NgPolicyFile -PolicyPath "$pd\policy.ini" -Key $w7Key
L "[Win7] 文件已投放，策略已用离线密钥签名"

# 服务设为自动启动 + 关 UAC（便于现场用 cmd 演示）
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\DW7' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\DW7\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $csKey = "HKLM:\DW7\ControlSet00$cur\Services\NetGuard"
    New-Item -Path $csKey -Force | Out-Null
    Set-ItemProperty $csKey -Name Type         -Value 0x10 -Type DWord
    Set-ItemProperty $csKey -Name Start        -Value 2 -Type DWord
    Set-ItemProperty $csKey -Name ErrorControl -Value 1 -Type DWord
    Set-ItemProperty $csKey -Name ImagePath    -Value 'C:\NetGuard\NetGuard.exe' -Type ExpandString
    Set-ItemProperty $csKey -Name ObjectName   -Value 'LocalSystem' -Type String
    Set-ItemProperty $csKey -Name DisplayName  -Value 'NetGuard Egress Control' -Type String
    L "[Win7] 服务已注册为自动启动"
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\DW7' 2>&1 | Out-Null
}
$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\DW7S' $sw 2>&1 | Out-Null
if ($?) {
    Set-NgOfflineKey -LoadedHive 'DW7S' -Key $w7Key
    $sysPol = 'HKLM:\DW7S\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty $sysPol -Name EnableLUA -Value 0 -Type DWord
    Set-ItemProperty $sysPol -Name DisableCAD -Value 1 -Type DWord
    $wl = 'HKLM:\DW7S\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $wl -Name AutoAdminLogon  -Value '1' -Type String
    Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
    Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
    Set-ItemProperty $wl -Name DefaultDomainName -Value 'FREEZE-PC' -Type String
    Set-ItemProperty $wl -Name ForceAutoLogon  -Value '1' -Type String
    L "[Win7] UAC=0 / 自动登录 FREEZE-PC\freeze / 免 Ctrl+Alt+Del"
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\DW7S' 2>&1 | Out-Null
}
[GC]::Collect()
Dismount-VHD -Path $vhd
Start-VM -Name $w7
L "[Win7] 已开机"

# 打开两个控制台窗口方便你直接看
try { Start-Process vmconnect.exe -ArgumentList 'localhost', $w7 } catch {}
try { Start-Process vmconnect.exe -ArgumentList 'localhost', $w10 } catch {}
L "已打开两台虚拟机的控制台窗口"
L "完成"
