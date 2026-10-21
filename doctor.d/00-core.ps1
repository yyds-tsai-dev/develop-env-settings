# Core doctor checks (PowerShell twin of 00-core.sh).

function check_chezmoi_present {
    $local = Join-Path $script:DoctorRoot '.tools/bin/chezmoi.exe'
    if ((Get-Command chezmoi -ErrorAction SilentlyContinue) -or (Test-Path $local)) { return $null }
    return @{ Status = 'FAIL'; Reason = 'chezmoi not on PATH and not in .tools/bin' }
}
Register 'check_chezmoi_present'

# WARN (never FAIL): an install script failed and left a retry marker holding a
# nonce; every apply reruns it until it succeeds (twin of 00-core.sh).
function check_install_retries {
    $d = Join-Path $HOME '.local/state/develop-env/retry'
    $pending = @(Get-ChildItem -Path $d -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($pending.Count -eq 0) { return $null }
    return @{ Status = 'WARN'; Reason = "install scripts waiting for a retry: $($pending -join ' '): re-run the bootstrap one-liner (irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex)" }
}
Register 'check_install_retries'
