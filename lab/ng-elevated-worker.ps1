# Elevated worker: run one or more .ps1 files listed in ng-elevated-command.txt
# Triggered by the existing "VM-Start-Win10" scheduled task through start-win10.ps1.
$ErrorActionPreference = 'Continue'
$root = 'C:\src\NetGuard\lab'
$log = Join-Path $root 'ng-elevated.log'
$done = Join-Path $root 'ng-elevated-done.txt'
function L($m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
Remove-Item $done -Force -ErrorAction SilentlyContinue
L '=== elevated worker start ==='
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p = New-Object Security.Principal.WindowsPrincipal($id)
L ('user=' + $id.Name + ' admin=' + $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

$cmdFile = Join-Path $root 'ng-elevated-command.txt'
$scripts = @()
if (Test-Path $cmdFile) {
    $scripts = Get-Content $cmdFile | Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') }
}
L ('scripts=' + ($scripts -join ' ; '))
foreach ($sc in $scripts) {
    $sc = $sc.Trim()
    L ('--- START ' + $sc + ' ---')
    try {
        $base = [IO.Path]::GetFileNameWithoutExtension($sc)
        $out = Join-Path $root ($base + '.stdout.log')
        $err = Join-Path $root ($base + '.stderr.log')
        $pr = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sc) `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        L ('--- END ' + $sc + ' exit=' + $pr.ExitCode + ' stdout=' + $out + ' stderr=' + $err + ' ---')
        if (Test-Path $err) {
            $et = Get-Content $err -Raw -ErrorAction SilentlyContinue
            if ($et) { L ('stderr: ' + ($et -replace "`r?`n", ' | ')) }
        }
    } catch {
        L ('--- EXCEPTION ' + $sc + ': ' + $_.Exception.Message + ' ---')
    }
}

# 不再自动恢复启动脚本：由调用方在测试结束后恢复，避免覆盖新的单 VM 启动器。
L 'launcher restore skipped (managed by caller)'

Set-Content -Path $done -Value (Get-Date -Format o) -Encoding UTF8
L '=== elevated worker done ==='
