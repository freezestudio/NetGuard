# Shared helpers for NetGuard lab scripts.
# Policy signing now uses a per-install random key stored in
# HKLM\SOFTWARE\NetGuard\PolicyKey (guest) or a caller-supplied key for offline signing.

$script:NgExeHost = 'C:\src\NetGuard\build\NetGuard.exe'

function New-NgPolicyKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

# Sign a policy file on the host with an explicit key (offline provisioning).
# Uses a temporary ProgramData so the host's real NetGuard data is untouched.
function Sign-NgPolicyFile {
    param(
        [Parameter(Mandatory = $true)][string]$PolicyPath,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if (-not (Test-Path $PolicyPath)) { throw "policy not found: $PolicyPath" }

    $tmp = Join-Path $env:TEMP ('ng-sign-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $tmp 'NetGuard') -Force | Out-Null
    $dst = Join-Path $tmp 'NetGuard\policy.ini'
    Copy-Item $PolicyPath $dst -Force

    $old = $env:ProgramData
    try {
        $env:ProgramData = $tmp
        & $script:NgExeHost sign --key $Key | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "host sign failed (exit=$LASTEXITCODE)" }
        Copy-Item $dst $PolicyPath -Force
    } finally {
        $env:ProgramData = $old
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Write PolicyKey into an offline-loaded guest SOFTWARE hive, e.g. -LoadedHive W7V
function Set-NgOfflineKey {
    param(
        [Parameter(Mandatory = $true)][string]$LoadedHive,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $k = "HKLM:\$LoadedHive\NetGuard"
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -Path $k -Name PolicyKey -Value $Key -Type String
}

# Run NetGuard.exe sign inside a PowerShell Direct session (guest admin).
function Sign-NgGuestPolicy {
    param([Parameter(Mandatory = $true)]$Session)
    $out = Invoke-Command -Session $Session -ScriptBlock {
        & 'C:\NetGuard\NetGuard.exe' sign 2>&1
        "SIGN_EXIT=$LASTEXITCODE"
    }
    $out | ForEach-Object { Write-Output $_ }
    if (($out -join "`n") -notmatch 'SIGN_EXIT=0') {
        throw 'NetGuard sign failed in guest (session not elevated, or key access denied)'
    }
}
