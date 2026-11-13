Get-Command -Module Hyper-V | Where-Object { $_.Name -like '*TPM*' } | Select-Object Name,CommandType | Format-Table -AutoSize
'--- Set-VM TPM params ---'
(Get-Command Set-VM).Parameters.Keys | Where-Object { $_ -like '*Tpm*' }
'--- Get-VM ---'
Get-VM -Name 'Win11-Test' | Select-Object Name,State,Generation,TpmEnabled,KeyProtector | Format-List
'--- firmware ---'
Get-VMFirmware -VMName 'Win11-Test' | Select-Object SecureBoot,SecureBootTemplate | Format-List
