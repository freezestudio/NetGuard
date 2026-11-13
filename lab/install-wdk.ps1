$log = 'C:\src\NetGuard\lab\install-wdk.log'
$done = 'C:\src\NetGuard\lab\install-wdk-done.txt'
function L($m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
Remove-Item $done -Force -ErrorAction SilentlyContinue
'=== install WDK ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8
try {
    $wg = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
    if (-not $wg) {
        $cand = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path $cand) { $wg = $cand }
    }
    L ('winget=' + $wg)
    if (-not $wg) { throw 'winget not found' }
    $out = & $wg install --id Microsoft.WindowsWDK.10.0.26100 --exact --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { L ('  ' + $_) }
    L ('winget exit=' + $code)
} catch {
    L ('EXCEPTION: ' + $_.Exception.Message)
}
$km = @(Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'km\wdm.h' } | Where-Object { Test-Path $_ })
L ('km headers=' + ($km -join '; '))
$inf2cat = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter inf2cat.exe -ErrorAction SilentlyContinue |
           Select-Object -First 1
L ('inf2cat=' + $(if ($inf2cat) { $inf2cat.FullName } else { 'missing' }))
L 'done'
Set-Content $done (Get-Date -Format o) -Encoding UTF8
