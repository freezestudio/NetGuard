$RepoRoot = Split-Path $PSScriptRoot -Parent
& "$RepoRoot\lab\installer-driver-test.ps1" -VmName 'Win11-Test'
exit $LASTEXITCODE
