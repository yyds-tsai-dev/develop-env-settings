# Zotero checks (PowerShell twin of 63-zotero.sh): zotero-cli from the
# zotero-mcp-server uv tool (32-zotero), its skill for Claude Code and Codex,
# and the Secret config.

$script:ZoteroFix = 're-run the bootstrap one-liner (irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex)'
$script:ZoteroForce = "run chezmoi state delete-bucket --bucket=entryState, then $($script:ZoteroFix)"

function Get-ZoteroHint {
    if (Test-Path (Join-Path $HOME '.local/state/develop-env/retry/32-zotero')) { return $script:ZoteroFix }
    return $script:ZoteroForce
}

# FAIL: zotero-cli is not on PATH or does not run.
function check_zotero_cli {
    $ErrorActionPreference = 'Continue'   # local: stderr must not become a FAIL (PowerShell 5.1)
    if (-not (Get-Command zotero-cli -ErrorAction SilentlyContinue)) {
        return @{ Status = 'FAIL'; Reason = "zotero-cli not on PATH: $(Get-ZoteroHint)" }
    }
    & zotero-cli --help *> $null
    if ($LASTEXITCODE -eq 0) { return $null }
    return @{ Status = 'FAIL'; Reason = "zotero-cli --help failed: $(Get-ZoteroHint)" }
}
Register 'check_zotero_cli'

# WARN (never FAIL): the zotero-cli skill is missing for Claude Code or Codex.
function check_zotero_skills {
    $missing = @()
    foreach ($d in @('.claude/skills/zotero-cli', '.codex/skills/zotero-cli')) {
        $p = Join-Path $HOME $d
        if (-not (Test-Path (Join-Path $p 'SKILL.md')) -or -not (Test-Path (Join-Path $p 'reference.md'))) { $missing += $d }
    }
    if ($missing.Count -eq 0) { return $null }
    return @{ Status = 'WARN'; Reason = "zotero-cli skill missing: $($missing -join ' '): $(Get-ZoteroHint)" }
}
Register 'check_zotero_skills'

# WARN (never FAIL): the Secret ~/.config/zotero-mcp/config.json (from the
# Bitwarden item zotero) is missing. Skipped in -Ci.
function check_zotero_config {
    if ($script:DoctorCi) { return @{ Status = 'SKIP'; Reason = 'secret check skipped in -Ci' } }
    $f = Join-Path $HOME '.config/zotero-mcp/config.json'
    if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { return $null }
    return @{ Status = 'WARN'; Reason = "$f missing: create the Bitwarden item zotero (fields api_key, library_id), unlock Bitwarden (bw login; `$env:BW_SESSION = bw unlock --raw; bw sync), then $($script:ZoteroFix)" }
}
Register 'check_zotero_config'
