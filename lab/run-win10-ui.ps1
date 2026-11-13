$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Continue'
$hostOut="$RepoRoot\lab\final\win10"
$log="$RepoRoot\lab\run-win10-ui.log"
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== run win10 UI $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8
$cred=New-Object System.Management.Automation.PSCredential('freeze',(ConvertTo-SecureString '1' -AsPlainText -Force))
$s=New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred -ErrorAction Stop
$r=Invoke-Command -Session $s -ScriptBlock {
  $o=@()
  Remove-Item 'C:\ProgramData\NetGuard\admin.dat' -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path 'C:\NetGuard\captures' -Force | Out-Null
  Remove-Item 'C:\NetGuard\captures\*' -Force -ErrorAction SilentlyContinue
  & schtasks.exe /delete /tn NgUiTest /f 2>&1 | Out-Null
  $tr='powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\NetGuard\guest-ui-test.ps1 -OutDir C:\NetGuard\captures'
  & schtasks.exe /create /tn NgUiTest /tr $tr /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f 2>&1 | Out-Null
  & schtasks.exe /run /tn NgUiTest 2>&1 | Out-Null
  $o += "task_run_exit=$LASTEXITCODE"
  $o += (& query.exe user 2>&1)
  $o
}
$r | ForEach-Object { L "$_" }
$done=$false
for($i=0;$i -lt 60;$i++){
  Start-Sleep -Seconds 5
  $res=Invoke-Command -Session $s -ScriptBlock {
    if(Test-Path 'C:\NetGuard\captures\ui-test.result'){ Get-Content 'C:\NetGuard\captures\ui-test.result' } else { 'WAIT' }
  }
  if($res -eq 'PASS' -or $res -eq 'FAIL'){ L "UI result=$res"; $done=$true; break }
  if($i % 4 -eq 0){ L "  wait T+$($i*5)s" }
}
if(-not $done){ L 'UI timed out' }
try {
  $capOut=Join-Path $hostOut 'captures'
  New-Item -ItemType Directory -Path $capOut -Force | Out-Null
  Copy-Item -FromSession $s -Path 'C:\NetGuard\captures\*' -Destination $capOut -Force -ErrorAction SilentlyContinue
  L 'captures copied'
} catch { L "copy failed: $($_.Exception.Message)" }
Invoke-Command -Session $s -ScriptBlock { & schtasks.exe /delete /tn NgUiTest /f 2>&1 | Out-Null }
Remove-PSSession $s
'DONE' | Out-File $log -Append -Encoding utf8
