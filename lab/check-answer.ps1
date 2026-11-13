$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\check-answer.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 校验应答文件 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6; L "已关机" }

$ansVhd = "$VmsRoot\$vmName\answer.vhdx"
$v = Mount-VHD -Path $ansVhd -Passthru
Start-Sleep 2
$d = $v | Get-Disk
$vol = Get-Partition -DiskNumber $d.Number | Get-Volume | Where-Object { $_.DriveLetter }
$L_ = $vol.DriveLetter
L "应答盘: $($L_):  文件系统=$($vol.FileSystem)"
Get-ChildItem "$($L_):\" -Force | ForEach-Object { L "  $($_.Name) $($_.Length)" }

$xml = "$($L_):\autounattend.xml"
if (Test-Path $xml) {
    $raw = Get-Content $xml -Raw -Encoding UTF8
    L "长度: $($raw.Length) 字符"
    L "--- 前 3 行 ---"
    ($raw -split "`n" | Select-Object -First 3) | ForEach-Object { L "  $_" }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($xml)
        L "XML 解析: OK  根节点=$($doc.DocumentElement.Name)"
        $passes = $doc.SelectNodes("//*[local-name()='settings']") | ForEach-Object { $_.pass }
        L "pass 列表: $($passes -join ', ')"
        $idx = $doc.SelectSingleNode("//*[local-name()='Key'][text()='/IMAGE/INDEX']/following-sibling::*[1]")
        if ($idx) { L "IMAGE/INDEX = $($idx.InnerText)" }
        $cmds = $doc.SelectNodes("//*[local-name()='SynchronousCommand']")
        L "FirstLogonCommands 条数: $($cmds.Count)"
    } catch {
        L "XML 解析失败: $($_.Exception.Message)"
    }
} else { L "!! autounattend.xml 不存在" }

[GC]::Collect()
Dismount-VHD -Path $ansVhd
L "已卸载"
L "完成"
