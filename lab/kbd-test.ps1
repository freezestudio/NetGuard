$ErrorActionPreference='Continue'
$log='C:\src\NetGuard\lab\kbd-test.log'
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 键盘注入测试 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8
$vmName='Win7-Pro-x64'
$cs=Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$kbd=Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_Keyboard
L "kbd=$($kbd.CimInstanceProperties['KeyState'].Value)  state=$($cs.EnabledState)"

# 三种方式各试一次，每次后截图
Add-Type -AssemblyName System.Drawing
$svc=Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
function Cap($tag){
  $res=Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{TargetSystem=$cs;WidthPixels=[uint16]800;HeightPixels=[uint16]600}
  if($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0){
    $bmp=New-Object System.Drawing.Bitmap(800,600,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $r=New-Object System.Drawing.Rectangle(0,0,800,600)
    $d=$bmp.LockBits($r,[System.Drawing.Imaging.ImageLockMode]::WriteOnly,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData,0,$d.Scan0,$res.ImageData.Length)
    $bmp.UnlockBits($d); $bmp.Save("C:\src\NetGuard\lab\k-$tag.png",[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    L "  截图 k-$tag.png"
  } else { L "  截图失败 rv=$($res.ReturnValue)" }
}

L "[A] PressKey/ReleaseKey 0x1C (Enter)"
$r1=Invoke-CimMethod -InputObject $kbd -MethodName PressKey -Arguments @{KeyCode=[byte]28}
$r2=Invoke-CimMethod -InputObject $kbd -MethodName ReleaseKey -Arguments @{KeyCode=[byte]28}
L "  PressKey rc=$($r1.ReturnValue)  ReleaseKey rc=$($r2.ReturnValue)"
Start-Sleep 5; Cap 'A'

L "[B] TypeKey 0x1C"
$r3=Invoke-CimMethod -InputObject $kbd -MethodName TypeKey -Arguments @{KeyCode=[byte]28}
L "  TypeKey rc=$($r3.ReturnValue)"
Start-Sleep 5; Cap 'B'

L "[C] TypeScancodes '1c 9c'（小写无空格分隔试）"
$r4=Invoke-CimMethod -InputObject $kbd -MethodName TypeScancodes -Arguments @{Scancodes='1c 9c'}
L "  TypeScancodes rc=$($r4.ReturnValue)"
Start-Sleep 5; Cap 'C'

L "完成"
