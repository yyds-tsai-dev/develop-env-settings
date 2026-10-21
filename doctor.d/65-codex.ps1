# Codex checks (PowerShell twin of 65-codex.sh): install, MCP servers in
# config.toml, skills, bundle drift, login. -Ci: login is SKIP. On a plain
# Desktop only the url MCP servers and those whose command exists are expected,
# and the codebase-memory skill only when codebase-memory-mcp is installed.
# Skills are directory junctions on Windows (absolute by nature), so the sh
# twin's relative-link check does not apply.

$script:CodexFix = 're-run the bootstrap one-liner (irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex)'
# The Codex installer puts its bin dir on the user PATH only (new sessions).
if ($env:LOCALAPPDATA) { $env:Path = (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin') + [IO.Path]::PathSeparator + $env:Path }

function Get-CodexManifestLines { Get-Content -LiteralPath (Join-Path $script:DoctorRoot 'home/.chezmoidata/manifest.yaml') }
function Test-CodexDesktop { return ($script:DoctorRole -notin @('server', 'desktop+server')) }
function Test-CodexPresent { [bool](Get-Command codex -ErrorAction SilentlyContinue) }

# Get-CodexMcpNames: config names of the manifest MCP servers whose clients
# include codex; on a plain Desktop a command server only when its command is
# on PATH (a url server always).
function Get-CodexMcpNames {
    $in = $false; $n = ''; $c = ''
    foreach ($l in Get-CodexManifestLines) {
        if ($l -match '^[a-z_]+:') { $in = ($l -match '^mcp:'); continue }
        if (-not $in) { continue }
        if ($l -match '^  - name: *(\S+)') { $n = $Matches[1] -replace '^mcp-', ''; $c = '' }
        elseif ($l -match '^    command: *(\S+)') { $c = $Matches[1] }
        elseif ($l -match '^    clients:.*codex') {
            if ($c -and (Test-CodexDesktop) -and -not (Get-Command $c -ErrorAction SilentlyContinue)) { continue }
            $n
        }
    }
}

# Get-CodexBundles: "<name>|<claude_plugin>|<plugin_json>" per manifest codex.skill_bundles entry.
function Get-CodexBundles {
    $c = $false; $s = $false
    foreach ($l in Get-CodexManifestLines) {
        if ($l -match '^codex:') { $c = $true; continue }
        if ($l -match '^[a-z_]+:') { $c = $false; continue }
        if ($c -and $l -match '^  skill_bundles:') { $s = $true; continue }
        if ($c -and $l -match '^  [a-z_]+:') { $s = $false; continue }
        if ($c -and $s -and $l -match '^    - \{ name: *([^,} ]+)') {
            $n = $Matches[1]; $p = ''; $j = ''
            if ($l -match 'claude_plugin: *"?([^",}]+)') { $p = $Matches[1] }
            if ($l -match 'plugin_json: *"?([^",} ]+)') { $j = $Matches[1] }
            "$n|$p|$j"
        }
    }
}

# Get-CodexSkillDirs: claude.skills dirs that are also fetched for codex.
function Get-CodexSkillDirs {
    $s = $false
    foreach ($l in Get-CodexManifestLines) {
        if ($l -match '^  skills:') { $s = $true; continue }
        if ($l -match '^[a-z_]+:' -or $l -match '^  [a-z_]+:') { $s = $false; continue }
        if ($s -and $l -match 'codex: true' -and $l -match 'dir: *([^,} ]+)') { $Matches[1] }
    }
}

function check_codex_installed {
    $ErrorActionPreference = 'Continue'
    if (-not (Test-CodexPresent)) { return @{ Status = 'FAIL'; Reason = "codex not on PATH: $($script:CodexFix)" } }
    & codex --version *> $null
    if ($LASTEXITCODE -eq 0) { return $null }
    return @{ Status = 'FAIL'; Reason = 'codex --version failed' }
}
Register 'check_codex_installed'

# Every expected server is a [mcp_servers.<name>] table in ~/.codex/config.toml
# and sets tool_timeout_sec.
function check_codex_mcp {
    $cfg = Join-Path $HOME '.codex/config.toml'
    if (-not (Test-Path $cfg)) { return @{ Status = 'FAIL'; Reason = "$cfg missing: $($script:CodexFix)" } }
    $tables = @{}; $n = ''
    foreach ($l in Get-Content -LiteralPath $cfg) {
        if ($l -match '^\[mcp_servers\.([^.\]]+)\]$') { $n = $Matches[1]; $tables[$n] = $false; continue }
        if ($l -match '^\[') { $n = ''; continue }
        if ($n -and $l -match '^tool_timeout_sec *=') { $tables[$n] = $true }
    }
    $missing = @(); $notimeout = @()
    foreach ($s in Get-CodexMcpNames) {
        if (-not $tables.ContainsKey($s)) { $missing += $s }
        elseif (-not $tables[$s]) { $notimeout += $s }
    }
    if ($missing.Count -eq 0 -and $notimeout.Count -eq 0) { return $null }
    $r = @()
    if ($missing.Count) { $r += "MCP server(s) missing from config.toml: $($missing -join ' ')" }
    if ($notimeout.Count) { $r += "MCP server(s) with no tool_timeout_sec: $($notimeout -join ' ')" }
    return @{ Status = 'FAIL'; Reason = ($r -join '; ') }
}
Register 'check_codex_mcp'

# Every manifest bundle installed (recorded by the install script) and every
# recorded skill resolves to a SKILL.md.
function check_codex_skills {
    $sk = Join-Path $HOME '.codex/skills'
    $st = Join-Path $HOME '.codex/skill-bundles/.devenv-skills'
    if (-not (Test-Path $st)) { return @{ Status = 'FAIL'; Reason = "$st missing: $($script:CodexFix)" } }
    $lines = @(Get-Content -LiteralPath $st)
    $missing = @(); $broken = @()
    foreach ($b in Get-CodexBundles) {
        $name = ($b -split '\|')[0]
        if (-not ($lines | Where-Object { $_.StartsWith("bundle $name ") })) { $missing += $name }
    }
    $want = @(Get-CodexSkillDirs)
    if (-not (Test-CodexDesktop) -or (Get-Command codebase-memory-mcp -ErrorAction SilentlyContinue)) { $want += 'codebase-memory' }
    foreach ($d in $want) { if ($lines -notcontains "skill $d") { $missing += $d } }
    if (-not (Test-Path (Join-Path $sk 'codex-queue-workflow/SKILL.md'))) { $missing += 'codex-queue-workflow' }
    foreach ($l in $lines) {
        if ($l -match '^skill (.+)$' -and -not (Test-Path (Join-Path $sk "$($Matches[1])/SKILL.md"))) { $broken += $Matches[1] }
    }
    if ($missing.Count -eq 0 -and $broken.Count -eq 0) { return $null }
    $r = @()
    if ($missing.Count) { $r += "not installed: $($missing -join ' ')" }
    if ($broken.Count) { $r += "skill(s) not resolving to a SKILL.md: $($broken -join ' ')" }
    return @{ Status = 'FAIL'; Reason = (($r -join '; ') + ": $($script:CodexFix)") }
}
Register 'check_codex_skills'

# WARN (never FAIL) when a bundle's plugin.json version (its 12-char SHA when the
# file has none) differs from the version of Claude's installed plugin.
function check_codex_bundle_versions {
    $st = Join-Path $HOME '.codex/skill-bundles/.devenv-skills'
    $reg = Join-Path $HOME '.claude/plugins/installed_plugins.json'
    if (-not (Test-Path $st)) { return @{ Status = 'SKIP'; Reason = "no $st yet" } }
    if (-not (Test-Path $reg)) { return @{ Status = 'SKIP'; Reason = 'no Claude plugins installed' } }
    $lines = @(Get-Content -LiteralPath $st)
    $plugins = $null
    try { $plugins = (Get-Content -Raw -LiteralPath $reg | ConvertFrom-Json).plugins } catch { }
    $drift = @()
    foreach ($b in Get-CodexBundles) {
        $name, $plugin, $pj = $b -split '\|'
        if (-not $plugin -or -not $pj) { continue }
        $line = $lines | Where-Object { $_.StartsWith("bundle $name ") } | Select-Object -First 1
        if (-not $line) { continue }
        $dir = $line.Substring("bundle $name ".Length)
        $cv = ''
        try { $cv = "$((Get-Content -Raw -LiteralPath (Join-Path $HOME ".codex/skill-bundles/$dir/$pj") | ConvertFrom-Json).version)" } catch { }
        if (-not $cv) { $cv = ($dir -split '-')[-1] }
        $clv = ''
        if ($plugins -and $plugins.PSObject.Properties[$plugin]) { $clv = "$(@($plugins.$plugin)[0].version)" }
        if (-not $clv) { continue }
        if ($cv -ne $clv) { $drift += "$name(codex $cv, claude $clv)" }
    }
    if ($drift.Count -eq 0) { return $null }
    return @{ Status = 'WARN'; Reason = "Codex bundle and Claude plugin versions differ: $($drift -join ' ') (re-run the bootstrap one-liner; claude plugin update <plugin>)" }
}
Register 'check_codex_bundle_versions'

function check_codex_login {
    $ErrorActionPreference = 'Continue'
    if ($script:DoctorCi) { return @{ Status = 'SKIP'; Reason = 'login check skipped in -Ci' } }
    if (-not (Test-CodexPresent)) { return @{ Status = 'FAIL'; Reason = "codex not on PATH: $($script:CodexFix)" } }
    & codex login status *> $null
    if ($LASTEXITCODE -eq 0) { return $null }
    return @{ Status = 'FAIL'; Reason = 'not logged in: run codex login' }
}
Register 'check_codex_login'
