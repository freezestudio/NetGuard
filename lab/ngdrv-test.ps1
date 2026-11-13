param([string]$VmName = 'Win10-Pro-22H2')

$ErrorActionPreference = 'Stop'
$lab = 'C:\src\NetGuard\lab'
$log = Join-Path $lab 'ngdrv-test.log'
function L([string]$m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== ngdrv test ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8

# ---------------------------------------------------------------- host: cert + sign
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq 'CN=NetGuardTest' } | Select-Object -First 1
if (-not $cert) {
    L 'creating test code-signing cert'
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=NetGuardTest' `
             -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy Exportable -HashAlgorithm sha256
}
L ('cert thumbprint=' + $cert.Thumbprint)
$cer = Join-Path $lab 'NetGuardTest.cer'
Export-Certificate -Cert $cert -FilePath $cer -Force | Out-Null

$signtool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
if (-not (Test-Path $signtool)) { throw 'signtool missing' }
foreach ($f in @('C:\src\NetGuard\drv\out\nghello.sys','C:\src\NetGuard\drv\out\ngdrv.sys')) {
    if (Test-Path $f) {
        & $signtool sign /fd sha256 /sm /s My /sha1 $cert.Thumbprint $f | Out-Null
        L ('signed ' + $f)
    }
}

# ---------------------------------------------------------------- VM
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$vm = Get-VM -Name $VmName
if ($vm.State -ne 'Running') { Start-VM -Name $VmName }
$s = $null
for ($i = 0; $i -lt 40; $i++) {
    try { $s = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop; break } catch { Start-Sleep 5 }
}
if (-not $s) { throw 'PS Direct failed' }
L 'PS Direct connected'

Invoke-Command -Session $s -ScriptBlock {
    New-Item -ItemType Directory -Path 'C:\NetGuard\drv' -Force | Out-Null
} | Out-Null
Copy-Item 'C:\src\NetGuard\drv\out\nghello.sys' -ToSession $s -Destination 'C:\NetGuard\drv\nghello.sys' -Force
Copy-Item 'C:\src\NetGuard\drv\out\ngdrv.sys'   -ToSession $s -Destination 'C:\NetGuard\drv\ngdrv.sys' -Force
Copy-Item $cer -ToSession $s -Destination 'C:\NetGuard\drv\NetGuardTest.cer' -Force

$prep = Invoke-Command -Session $s -ScriptBlock {
    $out = [ordered]@{}
    & certutil.exe -addstore -f Root 'C:\NetGuard\drv\NetGuardTest.cer' 2>&1 | Out-Null
    & certutil.exe -addstore -f TrustedPublisher 'C:\NetGuard\drv\NetGuardTest.cer' 2>&1 | Out-Null
    $ts = (& bcdedit.exe /enum '{current}' 2>&1) -join "`n"
    $out['testsigning'] = ($ts -match 'testsigning\s+Yes')
    foreach ($svc in @('nghello','ngdrv')) {
        & sc.exe stop $svc 2>&1 | Out-Null
        & sc.exe delete $svc 2>&1 | Out-Null
    }
    $out
}
$prep | Format-List | Out-String | ForEach-Object { L ('  ' + $_) }
if (-not $prep['testsigning']) { L 'WARN testsigning not enabled' }

# 1) hello driver load
$r = Invoke-Command -Session $s -ScriptBlock {
    & sc.exe create nghello type= kernel start= demand binPath= 'C:\NetGuard\drv\nghello.sys' 2>&1 | Out-Null
    & sc.exe start nghello 2>&1
    Start-Sleep 2
    (& sc.exe query nghello 2>&1) -join "`n"
}
L ('hello: ' + ($r -replace "`r?`n", ' | '))

# 2) 部署新的用户态构建并启动驱动
$r = Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 2
    'service stopped'
}
L ('service: ' + $r)
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe' -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
$r = Invoke-Command -Session $s -ScriptBlock {
    & sc.exe start NetGuard 2>&1 | Out-Null
    # 服务启动时会先 ApplyOnce + RunSelfTest，再开 IPC；等它真正可用。
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep 2
        $st = (& 'C:\NetGuard\NetGuard.exe' ctl status 2>&1) -join "`n"
        if ($st -match 'filters=') { $ready = $true; break }
    }
    & sc.exe create ngdrv type= kernel start= demand binPath= 'C:\NetGuard\drv\ngdrv.sys' 2>&1 | Out-Null
    Start-Sleep 2
    $q = (& sc.exe start ngdrv 2>&1) -join ' | '
    Start-Sleep 2
    [pscustomobject]@{ Ready = $ready; Start = $q; Query = ((& sc.exe query ngdrv 2>&1) -join ' | ') }
}
L ('service ready=' + $r.Ready + ' ngdrv start=' + $r.Start + ' query=' + $r.Query)

# 3) 用户态策略允许 ngblock.exe -> 8.8.8.8:53；服务应把 H1 下发给驱动
$h = Invoke-Command -Session $s -ScriptBlock {
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\NetGuard\ngblock.exe' -Force
    (& 'C:\NetGuard\NetGuard.exe' hash 'C:\NetGuard\ngblock.exe').Trim()
}
L ('ngblock hash=' + $h)

$policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=DNS
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1

[proc.1]
Name=ngblock
Path=C:\NetGuard\ngblock.exe
Sha256=$h
Endpoint=DNS
Enable=1
"@
[IO.File]::WriteAllText((Join-Path $lab 'policy-ngdrv-ioctl.ini'), ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $lab 'policy-ngdrv-ioctl.ini') -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = Invoke-Command -Session $s -ScriptBlock {
    & 'C:\NetGuard\NetGuard.exe' sign 2>&1 | Out-Null
    (& 'C:\NetGuard\NetGuard.exe' ctl apply 2>&1) -join ' '
}
L ('netguard apply: ' + $r)
Start-Sleep 2
$dst = Invoke-Command -Session $s -ScriptBlock {
    Get-ItemProperty 'HKLM:\SOFTWARE\NetGuard\DriverTest' -ErrorAction SilentlyContinue |
        Select-Object LastStep,LastStatus | Format-List | Out-String
}
L ('driver status: ' + $dst)
$nglog = Invoke-Command -Session $s -ScriptBlock {
    Get-Content 'C:\ProgramData\NetGuard\ng.log' -Tail 20 -ErrorAction SilentlyContinue
}
L ('ng.log tail: ' + (($nglog -join ' | ')))

# 4) 正确哈希：驱动 CONTINUE + 用户态 permit -> 放行
$r1 = Invoke-Command -Session $s -ScriptBlock {
    $curl = & 'C:\NetGuard\ngblock.exe' -s -o NUL -m 5 --connect-timeout 3 https://8.8.8.8:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($curl -join ' ') }
}
L ('correct hash: curl exit=' + $r1.Exit + ' out=' + $r1.Out)

# 正确哈希的进程访问“未列目标”仍应被用户态默认拒绝拦住（驱动必须返回 CONTINUE）
$r1b = Invoke-Command -Session $s -ScriptBlock {
    $curl = & 'C:\NetGuard\ngblock.exe' -s -o NUL -m 5 --connect-timeout 3 https://114.114.114.114:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($curl -join ' ') }
}
L ('correct hash other-dest: curl exit=' + $r1b.Exit + ' out=' + $r1b.Out)

# 5) 替换文件（追加字节）后立即运行：用户态 permit 仍在，但驱动应按 H2 != H1 拦截
$r2 = Invoke-Command -Session $s -ScriptBlock {
    $fs = [IO.File]::Open('C:\NetGuard\ngblock.exe', 'Append')
    $b = [Text.Encoding]::ASCII.GetBytes('NG-DRV-TAMPER')
    $fs.Write($b, 0, $b.Length); $fs.Close()
    $curl = & 'C:\NetGuard\ngblock.exe' -s -o NUL -m 5 --connect-timeout 3 https://8.8.8.8:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($curl -join ' ') }
}
L ('tampered hash: curl exit=' + $r2.Exit + ' out=' + $r2.Out)
$drvOk = ($r1.Exit -ne 7) -and ($r1b.Exit -eq 7) -and ($r2.Exit -eq 7)
L ('RESULT: ' + $(if ($drvOk) { 'WIN10 DRIVER TEST OK' } else { 'WIN10 DRIVER TEST FAIL' }))

# 5) cleanup
$cleanup = Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop ngdrv 2>&1 | Out-Null
    & sc.exe delete ngdrv 2>&1 | Out-Null
    & sc.exe stop nghello 2>&1 | Out-Null
    & sc.exe delete nghello 2>&1 | Out-Null
    Remove-Item 'C:\NetGuard\ngblock.exe' -Force -ErrorAction SilentlyContinue
    $relax = @"
[general]
DefaultDeny=0
AllowDhcp=1
AllowLoopback=1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=placeholder
Cidr=10.10.10.10/32
Ports=8000
Proto=TCP
Enable=1
"@
    [IO.File]::WriteAllText('C:\ProgramData\NetGuard\policy.ini', ($relax -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
    & 'C:\NetGuard\NetGuard.exe' sign 2>&1 | Out-Null
    (& 'C:\NetGuard\NetGuard.exe' ctl apply 2>&1) -join ' '
}
L ('cleanup: ' + $cleanup)
Remove-PSSession $s -ErrorAction SilentlyContinue
L 'done'
