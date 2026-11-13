$ErrorActionPreference = 'Continue'
. 'C:\src\NetGuard\lab\ng-lab-common.ps1'
$log = 'C:\src\NetGuard\lab\ui-test.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 管理界面验证 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Running') { Start-VM -Name $vmName; Start-Sleep 40 }
L "VM 状态: $((Get-VM -Name $vmName).State)"

$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred

# 1) 生成管理员口令文件（salt + HMAC-SHA256(salt, "1")），跳过首次设置对话框
$salt = -join ((1..32) | ForEach-Object { '{0:X}' -f (Get-Random -Max 16) })
$hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($salt))
$hash = ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes('1')) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
[IO.File]::WriteAllText('C:\src\NetGuard\lab\admin.dat', "$salt`r`n$hash`r`n", (New-Object Text.UTF8Encoding($false)))
L "已生成 admin.dat（口令 1）"

# 2) 部署
Invoke-Command -Session $s -ScriptBlock {
    New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null
    New-Item -ItemType Directory -Path 'C:\ProgramData\NetGuard' -Force | Out-Null
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
}
Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' -ToSession $s -Destination 'C:\NetGuard\NetGuardUI.exe' -Force
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe'   -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item 'C:\src\NetGuard\lab\admin.dat'        -ToSession $s -Destination 'C:\ProgramData\NetGuard\admin.dat' -Force
Copy-Item 'C:\src\NetGuard\lab\policy-win10.ini' -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
Sign-NgGuestPolicy -Session $s | ForEach-Object { L "  $_" }
L "文件已部署"

# 3) 启动 UI（PS Direct 会话是管理员，GUI 会出现在桌面）
Invoke-Command -Session $s -ScriptBlock {
    Start-Process 'C:\NetGuard\NetGuardUI.exe' -WorkingDirectory 'C:\NetGuard'
    Start-Sleep 4
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, MainWindowTitle
} | ForEach-Object { L "  $_" }

Start-Sleep 5
# 4) 打开 VMConnect 便于后续键盘输入 + 截图
try { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName } catch {}
Start-Sleep 6

Add-Type -AssemblyName System.Drawing
$cs  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
for ($i = 0; $i -lt 3; $i++) {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $r = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d); $bmp.Save('C:\src\NetGuard\lab\ui1.png', [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        L "截图 ui1.png"; break
    } else { L "缩略图 rv=$($res.ReturnValue)"; Start-Sleep 5 }
}
Remove-PSSession $s
L "完成"
