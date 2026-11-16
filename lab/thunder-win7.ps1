$VmsRoot  = 'C:\VMs'
$dir = "$VmsRoot\iso-rebuild"
$url = 'ed2k://|file|cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso|3420557312|430BEDC0F22FA18001F717F7AF08C9D5|/'
$name = 'cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso'
$a = New-Object -ComObject ThunderAgent.Agent.1
$a.AddTask.Invoke([object[]]@($url, $name, 'C:\迅雷下载', '', '', 1, 0, 5)) | Out-Null
$a.CommitTasks() | Out-Null
"task added"
