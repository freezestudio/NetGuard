# 生成交付包：dist\NetGuard-<版本>-<日期>.zip
$ErrorActionPreference = 'Stop'
$root = 'C:\src\NetGuard'
$ver = '1.0.0-dev'
$stamp = Get-Date -Format 'yyyyMMdd'
$name = "NetGuard-$ver-$stamp"
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist $name
$zip = Join-Path $dist "$name.zip"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
if (Test-Path $zip) { Remove-Item $zip -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'docs') -Force | Out-Null

# ---- 程序与脚本 ----
foreach ($f in @('NetGuard.exe', 'NetGuardUI.exe', 'install-netguard.ps1', 'uninstall-netguard.ps1')) {
    Copy-Item (Join-Path $root "build\$f") (Join-Path $stage $f) -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $stage $f))) { Copy-Item (Join-Path $root $f) (Join-Path $stage $f) }
}

# 可选：WFP callout 驱动（测试签名版；正式交付需替换为 EV/WHQL 签名）
$drvOut = Join-Path $root 'drv\out'
if (Test-Path (Join-Path $drvOut 'ngdrv.sys')) {
    New-Item -ItemType Directory -Path (Join-Path $stage 'drv') -Force | Out-Null
    Copy-Item (Join-Path $drvOut 'ngdrv.sys') (Join-Path $stage 'drv\ngdrv.sys') -Force
    Copy-Item (Join-Path $root 'drv\README.md') (Join-Path $stage 'drv\README.md') -Force
}

# ---- 文档：包里只放 PDF 教程（md/html/图片仅用于生成 PDF，不打包）----
Copy-Item (Join-Path $root 'docs\管控有效性说明.md') (Join-Path $stage 'docs\effectiveness.md')

$buildDir = Join-Path $env:TEMP ("ng-pdf-" + $stamp)
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $buildDir 'images') -Force | Out-Null
Copy-Item (Join-Path $root 'docs\images\tutorial') (Join-Path $buildDir 'images\tutorial') -Recurse

# ---- 教程 PDF 源：Markdown -> HTML（临时目录）----
$md = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'docs\新手教程.md')
$conv = ConvertFrom-Markdown -InputObject $md
$css = @'
body { font-family: "Microsoft YaHei", "Segoe UI", sans-serif; margin: 0; background: #f5f6f8; color: #222; line-height: 1.7; }
.wrap { max-width: 980px; margin: 0 auto; background: #fff; padding: 36px 48px 64px; box-shadow: 0 0 12px rgba(0,0,0,.08); }
h1 { border-bottom: 3px solid #2d6cdf; padding-bottom: 12px; }
h2 { margin-top: 42px; border-left: 5px solid #2d6cdf; padding-left: 12px; }
h3 { margin-top: 28px; }
img { max-width: 100%; border: 1px solid #d5d9e0; border-radius: 4px; box-shadow: 0 2px 8px rgba(0,0,0,.10); margin: 10px 0 18px; }
table { border-collapse: collapse; width: 100%; margin: 14px 0 22px; }
th, td { border: 1px solid #d5d9e0; padding: 8px 10px; text-align: left; vertical-align: top; }
th { background: #eef3fc; }
code { background: #f2f3f5; padding: 1px 5px; border-radius: 3px; font-family: Consolas, monospace; }
pre { background: #1e1e1e; color: #e8e8e8; padding: 14px 16px; border-radius: 6px; overflow-x: auto; }
pre code { background: transparent; color: inherit; padding: 0; }
blockquote { border-left: 4px solid #f0ad4e; background: #fff8ec; margin: 14px 0; padding: 8px 14px; color: #6b4b12; }
@media print {
  body { background: #fff; }
  .wrap { box-shadow: none; max-width: none; padding: 0; }
  img { page-break-inside: avoid; }
  h1, h2, h3 { page-break-after: avoid; }
  pre, table, blockquote { page-break-inside: avoid; }
  a { color: #000; text-decoration: none; }
}
'@
$html = @"
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>NetGuard 新手图文操作教程</title>
<style>$css</style>
</head>
<body>
<div class="wrap">
$($conv.Html)
</div>
</body>
</html>
"@
[IO.File]::WriteAllText((Join-Path $buildDir 'tutorial.html'), $html, (New-Object System.Text.UTF8Encoding($true)))

# ---- 教程 PDF（Edge 无头打印；图片、表格一起排版）----
$htmlPath = Join-Path $buildDir 'tutorial.html'
$pdfPath  = Join-Path $stage 'docs\tutorial.pdf'
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }
if (-not (Test-Path $edge)) { throw '未找到 Microsoft Edge，无法生成 PDF' }
$htmlUri = ([Uri]$htmlPath).AbsoluteUri
& $edge --headless=new --disable-gpu --no-sandbox --no-pdf-header-footer `
        --run-all-compositor-stages-before-draw --virtual-time-budget=20000 `
        "--print-to-pdf=$pdfPath" $htmlUri 2>$null | Out-Null
for ($i = 0; $i -lt 40 -and -not (Test-Path $pdfPath); $i++) { Start-Sleep -Milliseconds 500 }
if (-not (Test-Path $pdfPath)) { throw 'PDF 生成失败' }
Write-Host "PDF  : $pdfPath ($((Get-Item $pdfPath).Length) bytes)"
Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue

# ---- 一键安装 / 卸载入口（GBK，Win7 记事本和 cmd 都不会乱码）----
$gbk = [System.Text.Encoding]::GetEncoding(936)
$installCmd = @'
@echo off
setlocal
cd /d "%~dp0"
fltmc >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b
)
echo ================================================================
echo   NetGuard 安装（需要管理员权限）
echo ================================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-netguard.ps1"
echo.
echo 安装结束。请按任意键关闭此窗口。
pause >nul
'@
[IO.File]::WriteAllText((Join-Path $stage 'install.cmd'), ($installCmd -replace "`r?`n", "`r`n"), $gbk)

$uninstallCmd = @'
@echo off
setlocal
cd /d "%~dp0"
fltmc >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b
)
echo ================================================================
echo   NetGuard 卸载（会先撤销策略、恢复联网，再删除服务）
echo ================================================================
echo.
choice /c YN /m "确定要卸载 NetGuard 并恢复联网吗"
if errorlevel 2 exit /b
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-netguard.ps1"
echo.
echo 卸载结束。请按任意键关闭此窗口。
pause >nul
'@
[IO.File]::WriteAllText((Join-Path $stage 'uninstall.cmd'), ($uninstallCmd -replace "`r?`n", "`r`n"), $gbk)

# ---- 快速上手 ----
$readme = @"
NetGuard 药店终端出网白名单
版本 1.0.0-trial（60 天试用版，2026-11-12）

一、这个包里有什么
  NetGuard.exe              命令行（生成策略、看状态、临时放行）
  NetGuardUI.exe            管理界面（日常改策略用这个）
  install-netguard.ps1      安装脚本（建密钥、校验、装服务）
  uninstall-netguard.ps1    卸载脚本（先恢复联网再删服务）
  install.cmd               一键安装（会自动请求管理员权限）
  uninstall.cmd             一键卸载
  docs\tutorial.pdf         图文教程 PDF（21 张实机截图，建议先看）
  docs\effectiveness.md     给上级检查/内部审计看的技术说明
  START-HERE.txt            本文件
  SHA256SUMS.txt            所有文件的 SHA-256 校验值

二、安装前准备
  1. 一台 Windows 7 SP1 / Windows 10 / Windows 11 终端，本地管理员账户。
  2. 业务信息：服务器 IP、端口、TCP/UDP、业务程序完整路径。
  3. 想好装完怎么维护：默认断网，远程桌面可能连不上；
     提前约定现场操作，或用界面的「临时放行」。
  4. 第一次请先在备用机/虚拟机试装。

三、安装（三步）
  1. 把整个文件夹复制到目标机，例如 C:\NetGuard
     （不要只复制 exe，脚本要和 exe 放在同一目录）
  2. 双击「install.cmd」，UAC 点“是”，等到出现：服务状态: Running
  3. 双击 NetGuardUI.exe → 设置管理员口令 → 添加业务地址和业务程序
     → 点「保存并应用（下发到服务）」

四、验证
  以管理员身份打开命令提示符：
     cd /d C:\NetGuard
     NetGuard.exe status          （看“当前生效过滤器”和“签名: 有效”）
     NetGuard.exe trial           （看试用剩余天数）
     ping 8.8.8.8                 （应该超时/一般故障）
  再用业务程序访问业务地址，应该正常。

五、临时放行 / 立即恢复
  NetGuard.exe ctl temp 30       （临时放行 30 分钟，到期自动恢复）
  NetGuard.exe ctl apply         （立即恢复管控）
  NetGuard.exe ctl rollback      （撤销全部策略，恢复联网）

六、卸载
  双击「uninstall.cmd」。脚本会先通知服务撤销过滤器、恢复联网，再删除服务，
  不会留下“服务删了但网还断着”的状态。
  策略文件与部署密钥会保留（重装可复用）；彻底清理见教程第 17 节。

七、试用期说明（重要）
  - 本包是 60 天试用版，第一次安装/初始化时开始计时。
  - 查看剩余：NetGuard.exe trial；主界面底部状态栏也会显示。
  - 到期后：服务每 30 秒检查一次，自动撤销过滤器并恢复联网，
    不会把门店锁在断网状态；apply/temp/selftest 会被拒绝。
  - 续期：更换正式授权版本（替换 exe 重新安装即可，策略文件可保留）。
  - 试用信息在 HKLM\SOFTWARE\NetGuard（TrialStart/TrialSig）。
    删除这两个值可以重置试用，仅限测试环境；生产请按合同执行。

八、注意事项
  - 本包未做代码签名。如果目标机开启了 Smart App Control / 应用控制策略，
    可能拦截未签名的 exe；需要在策略里加白，或使用签名版本。
  - 示例策略里的 10.10.10.10、C:\Program Files\YB\YbClient.exe 都是占位值，
    必须改成门店真实地址和程序。
  - 界面口令不要用示例里的 1，现场请改成强口令。
  - 安装、改策略、卸载都需要管理员权限；员工日常使用标准账户即可。
  - 遇到问题先看 docs\tutorial.pdf 第 18 节“常见问题”，
    以及 C:\ProgramData\NetGuard\ 下的 audit.log / ng.log / install.log。

官网/技术支持：请填写你们自己的联系方式
"@
[IO.File]::WriteAllText((Join-Path $stage 'START-HERE.txt'), ($readme -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

# ---- 校验和 ----
$files = Get-ChildItem $stage -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object FullName
$lines = foreach ($f in $files) {
    $rel = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
    $h = (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash
    "$h  $rel"
}
$lines | Set-Content (Join-Path $stage 'SHA256SUMS.txt') -Encoding ASCII

# ---- 压缩 ----
New-Item -ItemType Directory -Path $dist -Force | Out-Null
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
$zipHash = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash
"$zipHash  $name.zip" | Set-Content "$zip.sha256" -Encoding ASCII

Write-Host "PKG  : $zip"
Write-Host "SHA  : $zipHash"
Write-Host "SIZE : $((Get-Item $zip).Length) bytes"
Write-Host "FILES: $((Get-ChildItem $stage -Recurse -File).Count)"
