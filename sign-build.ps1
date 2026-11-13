# NetGuard 构建产物代码签名（需已导入的代码签名证书）
# 用法:
#   powershell -ExecutionPolicy Bypass -File sign-build.ps1 -Thumbprint <证书指纹>
# 说明:
#   - 优先使用 PATH 中的 signtool.exe；否则自动查找 Windows Kits\10
#   - 同时签名并验签 NetGuard.exe / NetGuardUI.exe
param(
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = @(
    (Join-Path $here 'build\NetGuard.exe'),
    (Join-Path $here 'build\NetGuardUI.exe')
)

foreach ($f in $files) {
    if (-not (Test-Path $f)) { throw "未找到 $f，请先运行 build.bat" }
}

$signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source
if (-not $signtool) {
    $found = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" `
        -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
    if ($found) { $signtool = $found[0].FullName }
}
if (-not $signtool) {
    throw '未找到 signtool.exe；请在 Visual Studio Developer Command Prompt 或 Windows SDK 环境中运行'
}

foreach ($f in $files) {
    Write-Host "[*] 签名 $f"
    & $signtool sign /sha1 $Thumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $f
    if ($LASTEXITCODE -ne 0) { throw "签名失败: $f" }

    Write-Host "[*] 验签 $f"
    & $signtool verify /pa /v $f | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "验签失败: $f" }
}

Write-Host '[ok] NetGuard.exe / NetGuardUI.exe 已完成签名与验签'
