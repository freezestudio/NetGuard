$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\iso-answer.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 用数据 ISO 提供应答文件 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vmDir  = "$VmsRoot\$vmName"
$srcXml = "$RepoRoot\lab\autounattend-win7.xml"
$isoOut = "$vmDir\answer.iso"

if (-not (Test-Path $srcXml)) { L "缺少 $srcXml"; exit 1 }

# 1) 准备目录
$stage = "$RepoRoot\lab\answer-iso"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item $srcXml "$stage\autounattend.xml" -Force
L "暂存目录: $stage（autounattend.xml $((Get-Item "$stage\autounattend.xml").Length) 字节）"

# 2) 用 IMAPI2 生成 ISO
if (Test-Path $isoOut) { Remove-Item $isoOut -Force }
$code = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public class IsoMaker {
    public static void Create(string folder, string isoPath) {
        var fsi = new IMAPI2FS.MsftFileSystemImage();
        fsi.FileSystemsToCreate = IMAPI2FS.FsiFileSystems.Iso9660 | IMAPI2FS.FsiFileSystems.Joliet;
        fsi.VolumeName = "ANSWER";
        fsi.Root.AddTree(folder, false);
        var img = fsi.CreateResultImage();
        object streamObj = img.ImageStream;
        IStream stream = (IStream)streamObj;
        using (FileStream fs = new FileStream(isoPath, FileMode.Create, FileAccess.Write)) {
            byte[] buf = new byte[2048];
            IntPtr read = Marshal.AllocHGlobal(4);
            try {
                while (true) {
                    stream.Read(buf, 2048, read);
                    int n = Marshal.ReadInt32(read);
                    if (n <= 0) break;
                    fs.Write(buf, 0, n);
                }
            } finally { Marshal.FreeHGlobal(read); }
        }
    }
}
'@
try {
    Add-Type -TypeDefinition $code -Language CSharp -ReferencedAssemblies 'System.Runtime.InteropServices.ComTypes' -ErrorAction Stop
    [IsoMaker]::Create($stage, $isoOut)
    L "ISO 已生成: $isoOut ($((Get-Item $isoOut).Length) 字节)"
} catch {
    L "生成 ISO 失败: $($_.Exception.Message)"
}

if (-not (Test-Path $isoOut)) { exit 1 }

# 3) 挂到虚拟机：拔掉软驱、加第二个光驱(IDE 1:0)
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6; L "已关机" }

try { Set-VMFloppyDiskDrive -VMName $vmName -Path $null; L "已拔出虚拟软驱" } catch { L "拔软驱失败: $($_.Exception.Message)" }

$dvds = Get-VMDvdDrive -VMName $vmName
L "现有光驱: $(($dvds | ForEach-Object { "$($_.ControllerNumber):$($_.ControllerLocation)" }) -join ', ')"
$second = $dvds | Where-Object { $_.ControllerNumber -eq 1 }
if (-not $second) {
    try { Add-VMDvdDrive -VMName $vmName -ControllerNumber 1 -ControllerLocation 0 -ErrorAction Stop; L "已添加第二个光驱 1:0" }
    catch { L "添加第二光驱失败: $($_.Exception.Message)" }
}
$dvd2 = Get-VMDvdDrive -VMName $vmName | Where-Object { $_.ControllerNumber -eq 1 } | Select-Object -First 1
if ($dvd2) {
    Set-VMDvdDrive -VMName $vmName -ControllerNumber $dvd2.ControllerNumber -ControllerLocation $dvd2.ControllerLocation -Path $isoOut
    L "应答 ISO 挂到 $($dvd2.ControllerNumber):$($dvd2.ControllerLocation)"
}

L "--- 设备清单 ---"
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  HDD $($_.ControllerType)$($_.ControllerNumber):$($_.ControllerLocation) $(Split-Path -Leaf $_.Path)" }
Get-VMDvdDrive -VMName $vmName | ForEach-Object { L "  DVD $($_.ControllerNumber):$($_.ControllerLocation) $(Split-Path -Leaf $_.Path)" }

Set-VMBios -VMName $vmName -StartupOrder @('CD', 'IDE', 'LegacyNetworkAdapter', 'Floppy')
Start-VM -Name $vmName
L "已启动"
