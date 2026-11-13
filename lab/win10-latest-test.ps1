$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win10-latest-host.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win10 latest build test $(Get-Date -Format o) ===" | Set-Content $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Running') {
    L "starting VM"
    Start-VM -Name $vmName
    Start-Sleep 5
} else { L "VM already running" }

try { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName } catch { L "vmconnect failed: $($_.Exception.Message)" }

$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = $null
for ($i = 0; $i -lt 30; $i++) {
    try {
        $s = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop
        break
    } catch {
        if ($i % 3 -eq 0) { L "waiting PS Direct ($i): $($_.Exception.Message)" }
        Start-Sleep 5
    }
}
if (-not $s) { L "PS Direct FAILED"; exit 1 }
L "PS Direct ready"

# ---- clean ----
try {
    Invoke-Command -Session $s -ScriptBlock {
        & sc.exe stop NetGuard 2>&1 | Out-Null
        Start-Sleep 2
        & sc.exe delete NetGuard 2>&1 | Out-Null
        Get-Process NetGuard, NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 2
        Remove-Item 'C:\NetGuard', 'C:\ProgramData\NetGuard' -Recurse -Force -ErrorAction SilentlyContinue
        & reg.exe delete 'HKLM\SOFTWARE\NetGuard' /f 2>&1 | Out-Null
        Get-ChildItem "$env:windir\System32\Tasks" -Filter 'Ng*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\NetGuard*.vbs" -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null
        'cleaned'
    } | ForEach-Object { L "guest: $_" }
} catch { L "clean failed: $($_.Exception.Message)" }

# ---- deploy ----
$files = @(
    "$RepoRoot\build\NetGuard.exe",
    "$RepoRoot\build\NetGuardUI.exe",
    "$RepoRoot\install-netguard.ps1",
    "$RepoRoot\uninstall-netguard.ps1",
    "$RepoRoot\lab\win10-latest-guest.ps1"
)
foreach ($f in $files) {
    Copy-Item $f -ToSession $s -Destination ("C:\NetGuard\" + (Split-Path $f -Leaf)) -Force
    L "deployed $(Split-Path $f -Leaf)"
}

# ---- run guest suite ----
L "running guest suite (install / trial / test / temp / uninstall), may take 4-5 min"
try {
    Invoke-Command -Session $s -ScriptBlock {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\win10-latest-guest.ps1'
    } | ForEach-Object { L "  $_" }
} catch { L "guest suite error: $($_.Exception.Message)" }

# ---- collect ----
$outDir = "$RepoRoot\lab\win10-latest"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
try {
    Copy-Item -FromSession $s 'C:\NetGuard\latest.log' (Join-Path $outDir 'latest.log') -Force
    L "collected latest.log"
    $pd = Join-Path $outDir 'programdata'
    New-Item -ItemType Directory -Path $pd -Force | Out-Null
    Invoke-Command -Session $s -ScriptBlock { Get-ChildItem 'C:\ProgramData\NetGuard' -File -ErrorAction SilentlyContinue | Select-Object Name, Length } |
        ForEach-Object { L "  data: $($_.Name) $($_.Length)" }
    foreach ($n in @('policy.ini', 'ng.log', 'audit.log', 'install.log', 'filters.txt', 'selftest.txt')) {
        try { Copy-Item -FromSession $s "C:\ProgramData\NetGuard\$n" (Join-Path $pd $n) -Force } catch { }
    }
} catch { L "collect failed: $($_.Exception.Message)" }

L "--- latest.log tail ---"
$guestLog = Join-Path $outDir 'latest.log'
if (Test-Path $guestLog) { Get-Content $guestLog -Encoding UTF8 | Select-Object -Last 80 | ForEach-Object { L "  $_" } }

Remove-PSSession $s
L "DONE (VM left running)"
