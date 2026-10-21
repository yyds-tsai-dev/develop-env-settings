# Claude Code checks (PowerShell twin of 60-claude.sh): install, plugins, MCP
# servers, skills, status line, login. -Ci: login is SKIP. On a plain Desktop
# only the MCP servers whose command exists and the installer-made skills whose
# installer exists are expected (50-claude.ps1 skips the others with a warning;
# a .cmd/.ps1 npx is registered as `cmd /c npx`, under the same name).

$script:ClaudeFix = 're-run the bootstrap one-liner (irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex)'
$script:ClaudeForce = "run chezmoi state delete-bucket --bucket=entryState, then $($script:ClaudeFix)"

function Get-ClaudeManifestLines {
    Get-Content -LiteralPath (Join-Path $script:DoctorRoot 'home/.chezmoidata/manifest.yaml')
}

function Test-ClaudeDesktop { return ($script:DoctorRole -notin @('server', 'desktop+server')) }

function Test-ClaudePresent { [bool](Get-Command claude -ErrorAction SilentlyContinue) }

# Get-ClaudeSection SECTION: the lines of the manifest's claude.SECTION list.
function Get-ClaudeSection([string]$Section) {
    $in = $false; $topClaude = $false
    foreach ($l in Get-ClaudeManifestLines) {
        if ($l -match '^[a-z_]+:') { $topClaude = ($l -match '^claude:'); $in = $false; continue }
        if (-not $topClaude) { continue }
        if ($l -match '^  ?[a-z_]+:') { $in = ($l -match "^  ${Section}:"); continue }
        if ($in -and $l -match '^\s*- \{') { $l }
    }
}

# Get-ClaudeMcpNames: registered names (lock key minus "mcp-") of the manifest
# MCP servers whose clients include claude; on a plain Desktop only those whose
# command is on PATH.
function Get-ClaudeMcpNames {
    $in = $false; $n = ''; $c = ''
    foreach ($l in Get-ClaudeManifestLines) {
        if ($l -match '^[a-z_]+:') { $in = ($l -match '^mcp:'); continue }
        if (-not $in) { continue }
        if ($l -match '^  - name: *(\S+)') { $n = $Matches[1] -replace '^mcp-', ''; $c = '' }
        elseif ($l -match '^    command: *(\S+)') { $c = $Matches[1] }
        elseif ($l -match '^    clients:.*claude') {
            if ((Test-ClaudeDesktop) -and (-not $c -or -not (Get-Command $c -ErrorAction SilentlyContinue))) { continue }
            $n
        }
    }
}

# Get-ClaudeSkillDirs: the manifest skill dirs; on a plain Desktop an
# installer-made skill only when its installer command is on PATH.
function Get-ClaudeSkillDirs {
    foreach ($l in Get-ClaudeSection 'skills') {
        if ($l -notmatch 'dir: *([^,} ]+)') { continue }
        $d = $Matches[1]
        if ($l -match 'installer: *([^,} ]+)') {
            $i = $Matches[1]
            if ((Test-ClaudeDesktop) -and -not (Get-Command $i -ErrorAction SilentlyContinue)) { continue }
        }
        $d
    }
}

function check_claude_installed {
    $ErrorActionPreference = 'Continue'   # local: claude's stderr must not become a FAIL (PowerShell 5.1)
    if (-not (Test-ClaudePresent)) { return @{ Status = 'FAIL'; Reason = "claude not on PATH: $($script:ClaudeFix)" } }
    & claude --version *> $null
    if ($LASTEXITCODE -eq 0) { return $null }
    return @{ Status = 'FAIL'; Reason = 'claude --version failed' }
}
Register 'check_claude_installed'

function check_claude_plugins {
    $ErrorActionPreference = 'Continue'   # local: claude's stderr must not become a FAIL (PowerShell 5.1)
    if (-not (Test-ClaudePresent)) { return @{ Status = 'FAIL'; Reason = "claude not on PATH: $($script:ClaudeFix)" } }
    $list = (& claude plugin list --json 2>$null) -join "`n"
    $missing = @()
    foreach ($l in Get-ClaudeSection 'plugins') {
        if ($l -match 'name: *"([^"]+)"') {
            if (-not $list.Contains("""id"": ""$($Matches[1])""")) { $missing += $Matches[1] }
        }
    }
    if ($missing.Count -eq 0) { return $null }
    return @{ Status = 'FAIL'; Reason = "plugin(s) not installed: $($missing -join ' '): $($script:ClaudeFix)" }
}
Register 'check_claude_plugins'

# Every expected server must be registered and connect (`claude mcp list` runs
# a health check: a check mark and "Connected", or "Failed to connect ...").
function check_claude_mcp {
    $ErrorActionPreference = 'Continue'   # local: claude's stderr must not become a FAIL (PowerShell 5.1)
    if (-not (Test-ClaudePresent)) { return @{ Status = 'FAIL'; Reason = "claude not on PATH: $($script:ClaudeFix)" } }
    $list = @(& claude mcp list 2>$null)
    $missing = @(); $failed = @()
    foreach ($n in Get-ClaudeMcpNames) {
        $line = $list | Where-Object { $_.StartsWith("${n}:") } | Select-Object -First 1
        if (-not $line) { $missing += $n }
        elseif ($line -notmatch 'Connected') { $failed += "$n($(($line -split ' - ')[-1]))" }
    }
    if ($missing.Count -eq 0 -and $failed.Count -eq 0) { return $null }
    $r = @()
    if ($missing.Count) { $r += "MCP server(s) not registered: $($missing -join ' '): $($script:ClaudeFix)" }
    if ($failed.Count) { $r += "MCP server(s) not connecting: $($failed -join ' '): $($script:ClaudeForce)" }
    return @{ Status = 'FAIL'; Reason = ($r -join '; ') }
}
Register 'check_claude_mcp'

function check_claude_skills {
    $missing = @()
    foreach ($d in Get-ClaudeSkillDirs) {
        if (-not (Test-Path (Join-Path $HOME ".claude/skills/$d/SKILL.md"))) { $missing += $d }
    }
    if ($missing.Count -eq 0) { return $null }
    return @{ Status = 'FAIL'; Reason = "skill(s) missing from ~/.claude/skills: $($missing -join ' '): $($script:ClaudeFix)" }
}
Register 'check_claude_skills'

# WARN (never FAIL): the statusline release download failed and no go to build it.
function check_statusline_installed {
    if (Test-Path (Join-Path $HOME '.claude/statusline-bin.exe')) { return $null }
    return @{ Status = 'WARN'; Reason = "~/.claude/statusline-bin.exe missing (the statusline release download failed and no go to build it): $($script:ClaudeFix)" }
}
Register 'check_statusline_installed'

function check_claude_login {
    $ErrorActionPreference = 'Continue'   # local: claude's stderr must not become a FAIL (PowerShell 5.1)
    if ($script:DoctorCi) { return @{ Status = 'SKIP'; Reason = 'login check skipped in -Ci' } }
    if (-not (Test-ClaudePresent)) { return @{ Status = 'FAIL'; Reason = "claude not on PATH: $($script:ClaudeFix)" } }
    & claude auth status *> $null
    if ($LASTEXITCODE -eq 0) { return $null }
    return @{ Status = 'FAIL'; Reason = 'not logged in: run claude and /login' }
}
Register 'check_claude_login'
