$VmsRoot = Split-Path $PSScriptRoot -Parent
# 公共启动逻辑：同一时间只运行一台虚拟机，并且只保留一个远程连接窗口。
$ErrorActionPreference = 'Stop'
$script:VmLog = "$VmsRoot\launch\launcher.log"
$script:VmMutex = New-Object System.Threading.Mutex($false, 'Global\HyperV-OneVM-Launcher')

function Write-VmLog([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $script:VmLog -Value $line -Encoding UTF8
}

function Close-AllRemoteClients {
    $procs = @(Get-Process vmconnect, mstsc -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        Write-VmLog ('closing ' + $procs.Count + ' existing VMConnect/RDP window(s)')
        foreach ($p in $procs) { try { $p.CloseMainWindow() | Out-Null } catch { } }
        Start-Sleep -Milliseconds 800
        foreach ($p in @(Get-Process vmconnect, mstsc -ErrorAction SilentlyContinue)) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
}

function Stop-OtherVms([string]$Target) {
    foreach ($v in @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $Target })) {
        $other = $v.Name
        if ($v.State -eq 'Off' -or $v.State -eq 'Saved') {
            Write-VmLog ('other VM ' + $other + ' already ' + $v.State)
            continue
        }
        Write-VmLog ('stopping other VM ' + $other + ' (state=' + $v.State + ')')
        try {
            Stop-VM -Name $other -Save -Force -ErrorAction Stop
        } catch {
            Write-VmLog ('save failed, forcing off: ' + $_.Exception.Message)
            try { Stop-VM -Name $other -TurnOff -Force -ErrorAction Stop } catch { }
        }
        for ($i = 0; $i -lt 45; $i++) {
            Start-Sleep 1
            $s = (Get-VM -Name $other -ErrorAction SilentlyContinue).State
            if ($s -eq 'Off' -or $s -eq 'Saved') { break }
        }
        Write-VmLog ('other VM ' + $other + ' now ' + (Get-VM -Name $other -ErrorAction SilentlyContinue).State)
    }
}

function Start-OneVm([string]$Target, [switch]$NoConnect) {
    if (-not $script:VmMutex.WaitOne(60000)) { throw '另一个虚拟机启动器正在运行，请稍后重试' }
    try {
        Close-AllRemoteClients
        Stop-OtherVms $Target
        $v = Get-VM -Name $Target -ErrorAction Stop
        if ($v.State -eq 'Off' -or $v.State -eq 'Saved') {
            Write-VmLog ('starting ' + $Target + ' from ' + $v.State)
            Start-VM -Name $Target
        } else {
            Write-VmLog ($Target + ' already ' + $v.State)
        }
        for ($i = 0; $i -lt 45; $i++) {
            Start-Sleep 1
            if ((Get-VM -Name $Target).State -eq 'Running') { break }
        }
        if (-not $NoConnect) {
            Close-AllRemoteClients
            Start-Process vmconnect.exe -ArgumentList 'localhost', $Target
            Write-VmLog ('opened one VMConnect window for ' + $Target)
        }
    } finally {
        $script:VmMutex.ReleaseMutex()
    }
}
