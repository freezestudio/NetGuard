$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'vm-common.ps1')
try {
    Start-OneVm 'Win11-Test'
} catch {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("启动失败: $($_.Exception.Message)", 'Hyper-V') | Out-Null
}
