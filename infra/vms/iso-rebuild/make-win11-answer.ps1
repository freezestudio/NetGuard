$VmsRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$out = "$VmsRoot\iso-rebuild"
$src = Join-Path $out 'answer'
$iso = Join-Path $out 'autounattend-win11.iso'
New-Item -ItemType Directory -Path $src -Force | Out-Null

$xml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <Partition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></Partition>
            <Partition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></Partition>
            <Partition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></Partition>
          </CreatePartitions>
          <ModifyPartitions>
            <Partition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></Partition>
            <Partition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></Partition>
            <Partition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></Partition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><FullName>NetGuard</FullName><Organization>Lab</Organization></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>WIN11-TEST</ComputerName>
      <TimeZone>China Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
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
        <Password><Value>1</Value><PlainText>true</PlainText></Password>
        <Enabled>true</Enabled>
        <LogonCount>999</LogonCount>
        <Username>freeze</Username>
      </AutoLogon>
    </component>
  </settings>
</unattend>
'@
[IO.File]::WriteAllText((Join-Path $src 'autounattend.xml'), ($xml -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))

# IMAPI2FS: create ISO with autounattend.xml at root
if (Test-Path $iso) { Remove-Item $iso -Force }
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3
$fsi.VolumeName = 'AUTOUNATTEND'
$fsi.Root.AddTree($src, $false)
$result = $fsi.CreateResultImage()
$stream = $result.ImageStream
Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class IsoStreamHelper {
    public static void Save(object comStream, string path) {
        IStream s = (IStream)comStream;
        using (FileStream fs = File.Create(path)) {
            byte[] buf = new byte[65536];
            IntPtr read = Marshal.AllocHGlobal(4);
            try {
                while (true) {
                    s.Read(buf, buf.Length, read);
                    int n = Marshal.ReadInt32(read);
                    if (n <= 0) break;
                    fs.Write(buf, 0, n);
                }
            } finally {
                Marshal.FreeHGlobal(read);
            }
        }
    }
}
'@
[IsoStreamHelper]::Save($stream, $iso)
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
Write-Host ('ISO=' + $iso)
Get-Item $iso | Select-Object FullName,Length | Format-List

# verify
$m = Mount-DiskImage -ImagePath $iso -PassThru
Start-Sleep 2
$d = (Get-Volume -DiskImage $m).DriveLetter
Write-Host ('mounted=' + $d)
Get-ChildItem ($d + ':\') | Select-Object Name,Length | Format-Table -AutoSize
Dismount-DiskImage -ImagePath $iso | Out-Null
