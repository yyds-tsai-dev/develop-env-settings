# Core doctor checks (PowerShell twin of 00-core.sh).

function check_chezmoi_present {
    $local = Join-Path $script:DoctorRoot '.tools/bin/chezmoi.exe'
    if ((Get-Command chezmoi -ErrorAction SilentlyContinue) -or (Test-Path $local)) { return $null }
    return @{ Status = 'FAIL'; Reason = 'chezmoi not on PATH and not in .tools/bin' }
}
Register 'check_chezmoi_present'
