$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$log="$RepoRoot\lab\peek7.log"
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 窥屏 Win7 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8
$vmName='Win7-Pro-x64'
$st=Get-VM -Name $vmName
L "状态: $($st.State) CPU=$($st.CPUUsage)%"
Add-Type -AssemblyName System.Drawing
$cs=Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc=Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
for($i=0;$i -lt 3;$i++){
  $res=Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{TargetSystem=$cs;WidthPixels=[uint16]1024;HeightPixels=[uint16]768}
  if($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0){
    $bmp=New-Object System.Drawing.Bitmap(1024,768,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $r=New-Object System.Drawing.Rectangle(0,0,1024,768)
    $d=$bmp.LockBits($r,[System.Drawing.Imaging.ImageLockMode]::WriteOnly,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData,0,$d.Scan0,$res.ImageData.Length)
    $bmp.UnlockBits($d); $bmp.Save("$RepoRoot\lab\now7.png",[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    L "截图 now7.png"; break
  } else { L "缩略图 rv=$($res.ReturnValue)"; Start-Sleep 5 }
}
L 完成
