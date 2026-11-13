param([ValidateSet('Win7', 'Win10')][string]$Target)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'vm-common.ps1')

$name = if ($Target -eq 'Win7') { 'Win7-Pro-x64' } else { 'Win10-Pro-22H2' }
$staticIp = if ($Target -eq 'Win7') { '172.20.192.50' } else { '172.20.192.51' }

function Test-Tcp([string]$ip, [int]$port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($ip, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(1200)) { $c.EndConnect($ar); return $true }
        return $false
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function Find-VmIp([string]$vmName) {
    $macs = @()
    foreach ($a in (Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue)) {
        if ($a.MacAddress) { $macs += ($a.MacAddress -replace '[-:]', '').ToUpper() }
    }
    foreach ($n in (Get-NetNeighbor -InterfaceAlias 'vEthernet (Default Switch)' -ErrorAction SilentlyContinue)) {
        $m = ($n.LinkLayerAddress -replace '[-:]', '').ToUpper()
        if ($macs -contains $m) { return $n.IPAddress }
    }
    return $null
}

try {
    # 只启动这一台；关闭已有 VMConnect/RDP 窗口；另一台自动保存/关机
    Start-OneVm $name -NoConnect

    $ip = $staticIp
    $ok = $false
    for ($i = 0; $i -lt 90; $i++) {
        if (Test-Tcp $ip 3389) { $ok = $true; break }
        Start-Sleep 2
    }
    if (-not $ok) {
        $found = Find-VmIp $name
        if ($found -and (Test-Tcp $found 3389)) { $ip = $found; $ok = $true }
    }
    if (-not $ok) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show("无法连接 $name 的远程桌面（3389）。`n请先启动控制台窗口检查网络，或稍后重试。", 'Hyper-V') | Out-Null
        exit 1
    }

    # 保存凭据，避免每次输入密码
    & "$env:SystemRoot\System32\cmdkey.exe" /generic:"TERMSRV/$ip" /user:freeze /pass:1 | Out-Null

    # 显式启用剪贴板重定向
    $rdp = Join-Path $here ("rdp-$Target.rdp")
    $content = @"
screen mode id:i:2
use multimon:i:1
desktopwidth:i:1280
desktopheight:i:800
session bpp:i:32
full address:s:$ip
username:s:freeze
prompt for credentials:i:0
authentication level:i:0
enablecredsspsupport:i:1
redirectclipboard:i:1
redirectprinters:i:0
redirectcomports:i:0
redirectsmartcards:i:0
redirectdrives:i:0
audiomode:i:0
"@
    [IO.File]::WriteAllText($rdp, ($content -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
    Start-Process mstsc.exe -ArgumentList $rdp

    # 自动处理首次连接的安全警告：勾选“剪贴板”，点“连接”。
    # 只在还没连上时执行，避免在已连接的会话里误点。
    $accept = Join-Path $here 'accept-rdp.ps1'
    for ($i = 0; $i -lt 4; $i++) {
        Start-Sleep 5
        $p = Get-Process mstsc -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $p) { break }
        if ($p.MainWindowTitle -match [regex]::Escape($ip)) { break }
        if (Test-Path $accept) { & $accept }
    }
} catch {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("连接失败: $($_.Exception.Message)", 'Hyper-V') | Out-Null
    exit 1
}
