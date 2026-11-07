# rtk and ccusage checks (PowerShell twin of 62-rtk.sh).

$script:RtkFix = 're-run the bootstrap one-liner (irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex)'
$script:RtkForce = "run chezmoi state delete-bucket --bucket=entryState, then $($script:RtkFix)"

# Get-RtkHint SCRIPT: the fix when SCRIPT left a retry marker, else the forced rerun.
function Get-RtkHint([string]$Name) {
    if (Test-Path (Join-Path $HOME ".local/state/develop-env/retry/$Name")) { return $script:RtkFix }
    return $script:RtkForce
}

# FAIL: rtk missing or not at the locked version. WARN: `rtk init --show` does
# not report the Claude hook (`rtk hook claude` in ~/.claude/settings.json).
function check_rtk {
    $ErrorActionPreference = 'Continue'   # local: rtk's stderr must not become a FAIL (PowerShell 5.1)
    if (-not (Get-Command rtk -ErrorAction SilentlyContinue)) {
        return @{ Status = 'FAIL'; Reason = "rtk not on PATH: $(Get-RtkHint '35-rtk')" }
    }
    $want = ''
    foreach ($l in Get-Content -LiteralPath (Join-Path $script:DoctorRoot 'home/.chezmoidata/versions.yaml')) {
        if ($l -match "^  rtk: *'?([^']*)'?$") { $want = $Matches[1] }
    }
    $have = "$(& rtk --version 2>$null)".Trim()
    if ($want -and $have -ne "rtk $want") {
        return @{ Status = 'FAIL'; Reason = "rtk is $(if ($have) { $have } else { 'unknown' }), the Version lock wants ${want}: $(Get-RtkHint '35-rtk')" }
    }
    $show = @(& rtk init --show 2>$null)
    if ($show | Where-Object { $_ -match '^\[ok\] Hook:' }) { return $null }
    return @{ Status = 'WARN'; Reason = "rtk init --show reports no Claude hook (rtk hook claude in ~/.claude/settings.json): $($script:RtkFix)" }
}
Register 'check_rtk'

# WARN (never FAIL): ccusage (usage reports) is not on PATH; without a Node
# install on Windows it is not installed at all.
function check_ccusage {
    if (Get-Command ccusage -ErrorAction SilentlyContinue) { return $null }
    return @{ Status = 'WARN'; Reason = "ccusage not on PATH (needs a Node install's npm on Windows): $(Get-RtkHint '26-ccusage')" }
}
Register 'check_ccusage'
