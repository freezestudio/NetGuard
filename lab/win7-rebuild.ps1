$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Stop'
$log = "$RepoRoot\lab\win7-rebuild.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 重建 Win7 VM ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$iso    = "$VmsRoot\iso-rebuild\cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso"
$vmDir  = "$VmsRoot\$vmName"

if (-not (Test-Path $iso)) { L "缺少 ISO: $iso"; exit 1 }
L "ISO: $((Get-Item $iso).Length) 字节"

# ---- 1. 删掉旧 VM 与文件 ----
$old = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($old) {
    if ($old.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }
    Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue | Remove-VMSnapshot -ErrorAction SilentlyContinue
    Remove-VM -Name $vmName -Force
    L "已删除旧 VM"
}
Start-Sleep 3
Remove-Item $vmDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

# ---- 2. 创建 VM（Gen1 / BIOS）----
New-VM -Name $vmName -Generation 1 -MemoryStartupBytes 3GB `
       -NewVHDPath "$vmDir\disk.vhdx" -NewVHDSizeBytes 60GB | Out-Null
Set-VMProcessor      $vmName -Count 2
Set-VMMemory         $vmName -DynamicMemoryEnabled $false -StartupBytes 3GB
Add-VMNetworkAdapter $vmName -SwitchName 'Default Switch' -IsLegacy $true
Add-VMDvdDrive       $vmName
Set-VMComPort        $vmName -Path '\\.\pipe\win7dbg' -Number 1
Set-VM               $vmName -AutomaticStopAction ShutDown -AutomaticStartAction Nothing
# 去掉 New-VM 自带的合成网卡（Win7 没驱动）
Get-VMNetworkAdapter -VMName $vmName | Where-Object { -not $_.IsLegacy } |
    ForEach-Object { Remove-VMNetworkAdapter -VMName $vmName -Name $_.Name }
L "已创建 VM（Gen1 / 3GB / Legacy NIC / COM1 管道）"

# ---- 3. 生成应答盘（FAT32 小磁盘，根目录放 autounattend.xml）----
$ansVhd = "$vmDir\answer.vhdx"
New-VHD -Path $ansVhd -SizeBytes 256MB -Dynamic | Out-Null
$v = Mount-VHD -Path $ansVhd -Passthru
Start-Sleep 2
$d = $v | Get-Disk
Initialize-Disk -Number $d.Number -PartitionStyle MBR | Out-Null
$part = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel ANSWER -Confirm:$false | Out-Null
$L_ = (Get-Partition -DiskNumber $d.Number | Get-Volume).DriveLetter
L "应答盘挂载为 $($L_):"

$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>zh-CN</UILanguage></SetupUILanguage>
      <InputLocale>0804:00000804</InputLocale>
      <SystemLocale>zh-CN</SystemLocale>
      <UILanguage>zh-CN</UILanguage>
      <UserLocale>zh-CN</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>100</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>System Reserved</Label><Active>true</Active></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>3</Value></MetaData></InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>2</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <ProductKey><WillShowUI>Never</WillShowUI></ProductKey>
      </UserData>
    </component>
  </settings>
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
            <Name>freeze</Name>
            <DisplayName>freeze</DisplayName>
            <Group>Administrators</Group>
            <Password><Value>1</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled><Username>freeze</Username><LogonCount>2</LogonCount>
        <Password><Value>1</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c bcdedit /set testsigning on</CommandLine><Description>testsigning</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>cmd /c bcdedit /debug on</CommandLine><Description>kernel debug</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>cmd /c bcdedit /dbgsettings serial debugport:1 baudrate:115200</CommandLine><Description>serial dbg</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>4</Order><CommandLine>cmd /c powercfg -h off</CommandLine><Description>no hibernate</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>5</Order><CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine><Description>rdp on</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>6</Order><CommandLine>cmd /c netsh advfirewall firewall add rule name="RDP-3389" dir=in protocol=TCP localport=3389 action=allow</CommandLine><Description>rdp fw</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>7</Order><CommandLine>cmd /c echo ok &gt; C:\OOBE-DONE.txt</CommandLine><Description>marker</Description></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
[IO.File]::WriteAllText("$($L_):\autounattend.xml", ($xml -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
L "已写 autounattend.xml ($((Get-Item "$($L_):\autounattend.xml").Length) 字节)"
[GC]::Collect()
Dismount-VHD -Path $ansVhd
L "应答盘已卸载"

# 应答盘挂到 IDE 1:0
Add-VMHardDiskDrive -VMName $vmName -ControllerType IDE -ControllerNumber 1 -ControllerLocation 0 -Path $ansVhd

# ---- 4. 挂 ISO、设启动顺序、开机 ----
$dvd = Get-VMDvdDrive -VMName $vmName | Select-Object -First 1
Set-VMDvdDrive -VMName $vmName -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $iso
Set-VMBios -VMName $vmName -StartupOrder @('CD', 'IDE', 'LegacyNetworkAdapter', 'Floppy')
L "ISO 已挂载，启动顺序 CD 优先"

Start-VM -Name $vmName
Start-Sleep -Seconds 10
L "VM 状态: $((Get-VM -Name $vmName).State)"
L "完成（安装大约 20-30 分钟，自动无人值守）"
