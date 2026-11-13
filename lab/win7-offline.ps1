$ErrorActionPreference = 'Stop'
$log = 'C:\src\NetGuard\lab\win7-offline.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 离线部署 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vmDir  = "C:\VMs\$vmName"
$iso    = 'C:\VMs\iso-rebuild\cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso'

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6; L "已关机" }

# 1) 清掉所有设备，重建系统盘
foreach ($d in Get-VMHardDiskDrive -VMName $vmName) { Remove-VMHardDiskDrive -VMHardDiskDrive $d }
foreach ($d in Get-VMDvdDrive -VMName $vmName) { Remove-VMDvdDrive -VMName $vmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation }
try { Set-VMFloppyDiskDrive -VMName $vmName -Path $null } catch {}
Get-ChildItem $vmDir -Filter '*.vhdx' -ErrorAction SilentlyContinue | Remove-Item -Force
L "已清理旧设备与磁盘"

$vhd = "$vmDir\disk.vhdx"
New-VHD -Path $vhd -SizeBytes 60GB -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $vmName -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 -Path $vhd
L "新磁盘: $vhd (60GB, IDE 0:0)"

# 2) MBR 分区
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 2
$disk = $v | Get-Disk
Initialize-Disk -Number $disk.Number -PartitionStyle MBR | Out-Null
$sys = New-Partition -DiskNumber $disk.Number -Size 100MB
$pri = New-Partition -DiskNumber $disk.Number -UseMaximumSize
Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $sys.PartitionNumber -AccessPath 'S:\' | Out-Null
Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $pri.PartitionNumber -AccessPath 'W:\' | Out-Null
Start-Sleep 2
& diskpart /s NUL 2>&1 | Out-Null
# 标记活动分区（BIOS 引导必需）
$dp = @"
select disk $($disk.Number)
select partition $($sys.PartitionNumber)
active
exit
"@
$dpFile = "$env:TEMP\dp.txt"
Set-Content $dpFile $dp -Encoding ascii
& diskpart /s $dpFile | ForEach-Object { L "  diskpart: $_" }
Format-Volume -Partition (Get-Partition -DiskNumber $disk.Number -PartitionNumber $sys.PartitionNumber) -FileSystem NTFS -NewFileSystemLabel 'System Reserved' -Confirm:$false | Out-Null
Format-Volume -Partition (Get-Partition -DiskNumber $disk.Number -PartitionNumber $pri.PartitionNumber) -FileSystem NTFS -NewFileSystemLabel Windows -Confirm:$false | Out-Null
L "分区完成: 系统保留=S:   Windows=W:  (已标记 active)"

# 3) 应用 install.wim 索引 3（专业版）
$img = Mount-DiskImage -ImagePath $iso -Passthru
try {
    $dl = ($img | Get-Volume).DriveLetter
    $wim = "$($dl):\sources\install.wim"
    $imgs = Get-WindowsImage -ImagePath $wim
    foreach ($i in $imgs) { L ("  索引 {0}: {1}" -f $i.ImageIndex, $i.ImageName) }
    L "应用索引 3 -> W:\  (几分钟)"
    $t0 = Get-Date
    Expand-WindowsImage -ImagePath $wim -Index 3 -ApplyPath 'W:\' -ErrorAction Stop | Out-Null
    L ("应用完成，用时 {0:N1} 分钟" -f ((Get-Date) - $t0).TotalMinutes)
} finally { Dismount-DiskImage -ImagePath $iso | Out-Null }

# 4) 用镜像自带 bcdboot 建 BIOS 引导
$guestBcd = 'W:\Windows\System32\bcdboot.exe'
L "镜像 bcdboot 版本: $((Get-Item $guestBcd).VersionInfo.FileVersion)"
& $guestBcd 'W:\Windows' /s 'S:' /l zh-CN 2>&1 | ForEach-Object { L "  bcdboot: $_" }
L "bcdboot exit=$LASTEXITCODE"
L "  BCD 存在: $(Test-Path 'S:\Boot\BCD')   bootmgr: $(Test-Path 'S:\bootmgr')"
(& bcdedit /store 'S:\Boot\BCD' /enum 2>&1) | ForEach-Object { L "  $_" }

# 5) 预置 OOBE 应答文件（只保留 oobeSystem）
$oobe = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0804:00000804</InputLocale>
      <SystemLocale>zh-CN</SystemLocale>
      <UILanguage>zh-CN</UILanguage>
      <UserLocale>zh-CN</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>
      <TimeZone>China Standard Time</TimeZone>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>freeze</Name><DisplayName>freeze</DisplayName><Group>Administrators</Group>
            <Password><Value>1</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled><Username>freeze</Username><LogonCount>2</LogonCount>
        <Password><Value>1</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c bcdedit /set testsigning on</CommandLine><Description>ts</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>cmd /c bcdedit /debug on</CommandLine><Description>dbg</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>cmd /c bcdedit /dbgsettings serial debugport:1 baudrate:115200</CommandLine><Description>serial</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>4</Order><CommandLine>cmd /c powercfg -h off</CommandLine><Description>nohib</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>5</Order><CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine><Description>rdp</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>6</Order><CommandLine>cmd /c netsh advfirewall firewall add rule name="RDP-3389" dir=in protocol=TCP localport=3389 action=allow</CommandLine><Description>fw</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>7</Order><CommandLine>cmd /c echo ok &gt; C:\OOBE-DONE.txt</CommandLine><Description>marker</Description></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
[IO.File]::WriteAllText('W:\Windows\Panther\unattend.xml', ($oobe -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
L "已预置 W:\Windows\Panther\unattend.xml"

[GC]::Collect()
Dismount-VHD -Path $vhd
L "磁盘已卸载"

Set-VMBios -VMName $vmName -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy')
Start-VM -Name $vmName
Start-Sleep -Seconds 10
L "VM 状态: $((Get-VM -Name $vmName).State)"
L "完成（OOBE 自动跑，约 5-10 分钟）"
