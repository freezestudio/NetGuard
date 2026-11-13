$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\fixbcd7.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 修复 Win7 BCD 启动项 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$parts = Get-Partition -DiskNumber $disk.Number
$srL  = (($parts | Where-Object { $_.Size -lt 200MB } | Select-Object -First 1) | Get-Volume).DriveLetter
$bcdDir = "$($srL):\Boot"
$bcd = "$bcdDir\BCD"

# 恢复原始 BCD
if (Test-Path "$bcd.bak") { Copy-Item "$bcd.bak" $bcd -Force; L "已从 BCD.bak 恢复" }
L "BCD 存在: $(Test-Path $bcd)"

L "--- 当前条目（含标识符）---"
$dump = & bcdedit /store $bcd /enum all /v 2>&1
$dump | ForEach-Object { L "  $_" }

# 解析出「Windows 加载器」条目
$entries = @{}
$curId = $null
foreach ($line in $dump) {
    $t = $line.Trim()
    if ($t -match '^(标识符|identifier)\s+(\{[0-9a-fA-F-]+\}|\{[a-z]+\})') {
        $curId = $matches[2]
        if (-not $entries.ContainsKey($curId)) { $entries[$curId] = @{} }
    } elseif ($curId -and $t -match '^(path|device|osdevice|description)\s+(.+)$') {
        $entries[$curId][$matches[1]] = $matches[2].Trim()
    }
}

$biosId = $null; $efiId = $null
foreach ($k in $entries.Keys) {
    $p = [string]$entries[$k]['path']
    if ($p -match 'winload\.exe$') { $biosId = $k }
    elseif ($p -match 'winload\.efi$') { $efiId = $k }
}
L "BIOS 加载器条目: $(if ($biosId) { $biosId } else { '(未找到)' })"
L "UEFI 加载器条目: $(if ($efiId) { $efiId } else { '(无)' })"

# 删除 UEFI 条目
if ($efiId) { & bcdedit /store $bcd /delete $efiId /f 2>&1 | ForEach-Object { L "  删除 $efiId : $_" } }

if ($biosId) {
    & bcdedit /store $bcd /set '{bootmgr}' default $biosId 2>&1 | ForEach-Object { L "  set default: $_" }
    & bcdedit /store $bcd /set '{bootmgr}' displayorder $biosId 2>&1 | ForEach-Object { L "  set displayorder: $_" }
    & bcdedit /store $bcd /deletevalue '{bootmgr}' path 2>&1 | ForEach-Object { L "  删除 bootmgr.path: $_" }
    & bcdedit /store $bcd /set '{bootmgr}' timeout 5 2>&1 | ForEach-Object { L "  timeout: $_" }
    & bcdedit /store $bcd /set '{bootmgr}' locale zh-CN 2>&1 | ForEach-Object { L "  locale: $_" }
    & bcdedit /store $bcd /set $biosId device ('partition=' + (($parts | Sort-Object Size -Descending | Select-Object -First 1) | Get-Volume).DriveLetter + ':') 2>&1 | ForEach-Object { L "  device: $_" }
    & bcdedit /store $bcd /set $biosId osdevice ('partition=' + (($parts | Sort-Object Size -Descending | Select-Object -First 1) | Get-Volume).DriveLetter + ':') 2>&1 | ForEach-Object { L "  osdevice: $_" }
    & bcdedit /store $bcd /set $biosId path '\Windows\system32\winload.exe' 2>&1 | ForEach-Object { L "  path: $_" }
    & bcdedit /store $bcd /set $biosId systemroot '\Windows' 2>&1 | ForEach-Object { L "  systemroot: $_" }
}

L "--- 修复后 ---"
(& bcdedit /store $bcd /enum 2>&1) | ForEach-Object { L "  $_" }

[GC]::Collect()
Dismount-VHD -Path $target
L "已卸载，启动 VM"
Start-VM -Name $vmName
Start-Sleep -Seconds 80

Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
try {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rect = New-Object System.Drawing.Rectangle(0, 0, 800, 600)
        $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d)
        $bmp.Save('C:\src\NetGuard\lab\fixed.png', [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose(); L "截图 ok"
    } else { L "缩略图 rv=$($res.ReturnValue)" }
} catch { L "截图异常: $($_.Exception.Message)" }
L "完成"
