$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\setup7-2.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 Setup 键盘驱动 步骤2 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$cs  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$kbd = Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_Keyboard
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
Add-Type -AssemblyName System.Drawing

function Sc([string]$codes) {
    Invoke-CimMethod -InputObject $kbd -MethodName TypeScancodes -Arguments @{ Scancodes = $codes } | Out-Null
    L "  发送扫描码: $codes"
}
function Cap([string]$tag) {
    try {
        $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
            TargetSystem = $cs; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
        if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
            $bmp = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $rect = New-Object System.Drawing.Rectangle(0, 0, 800, 600)
            $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
            $bmp.UnlockBits($d)
            $bmp.Save("$RepoRoot\lab\s7-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            L "  截图 s7-$tag.png"
        } else { L "  缩略图 rv=$($res.ReturnValue)" }
    } catch { L "  截图异常: $($_.Exception.Message)" }
}

$ENTER = '1C 9C'
$ALT_A = '38 1E 9E B8'
$ALT_C = '38 2E AE B8'

L "[1] 语言界面 -> 下一步（Enter）"
Sc $ENTER; Start-Sleep 6; Cap 'a'

L "[2] 现在安装（Enter）"
Sc $ENTER; Start-Sleep 45; Cap 'b'

L "[3] 接受许可条款（Alt+A）然后下一步（Enter）"
Sc $ALT_A; Start-Sleep 2; Sc $ENTER; Start-Sleep 8; Cap 'c'

L "[4] 自定义安装（Alt+C）"
Sc $ALT_C; Start-Sleep 8; Cap 'd'

L "[5] 分区界面 -> 下一步（Enter，使用未分配空间）"
Sc $ENTER; Start-Sleep 12; Cap 'e'

L "[6] 等待安装开始（90 秒）"
Start-Sleep -Seconds 90; Cap 'f'
$st = Get-VM -Name $vmName
L "VM 状态: $($st.State) CPU=$($st.CPUUsage)%"
L "完成"
