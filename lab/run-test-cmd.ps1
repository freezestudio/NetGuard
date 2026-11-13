$ErrorActionPreference='Continue'
. 'C:\src\NetGuard\lab\ng-lab-common.ps1'
$log='C:\src\NetGuard\lab\test-cmd.log'
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== NetGuard test 命令端到端 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8
$cred=New-Object System.Management.Automation.PSCredential('freeze',(ConvertTo-SecureString '1' -AsPlainText -Force))
$s=New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
    & sc.exe stop NetGuard 2>&1 | Out-Null
    Start-Sleep 1
    & sc.exe delete NetGuard 2>&1 | Out-Null
    Get-Process NetGuard -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    New-Item -ItemType Directory -Path 'C:\NetGuard','C:\ProgramData\NetGuard' -Force | Out-Null
}
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe' -ToSession $s -Destination 'C:\NetGuard\NetGuard.exe' -Force
Copy-Item 'C:\src\NetGuard\lab\policy-win10.ini' -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
Sign-NgGuestPolicy -Session $s | ForEach-Object { L "  $_" }
$r = Invoke-Command -Session $s -ScriptBlock {
    $out='C:\NetGuard\test-out.txt'
    Remove-Item $out -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath 'C:\NetGuard\NetGuard.exe' -ArgumentList 'test' -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out
    "exit=$($p.ExitCode)"
    Get-Content $out
}
$r | ForEach-Object { L "  $_" }
Remove-PSSession $s
L 完成
