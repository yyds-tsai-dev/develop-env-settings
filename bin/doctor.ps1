#!/usr/bin/env pwsh
# Doctor (PowerShell 7). Same protocol as bin/doctor:
#   PASS <name> | FAIL <name>: <reason> | SKIP <name>: <reason>
#   | WARN <name>: <reason> (advisory, does not fail)
# Exit status 1 if any check FAILs. -Ci turns login and Secret checks into SKIP.
# $env:DOCTOR_ONLY=<glob> limits which doctor.d files are loaded (e.g. '00-*'); unset means all.
# $env:DEVENV_ROLE=<role> is the role when chezmoi cannot tell.
param([switch]$Ci)

$ErrorActionPreference = 'Stop'
$script:DoctorRoot = Split-Path -Parent $PSScriptRoot
$script:DoctorCi = [bool]$Ci
$script:DoctorChecks = @()

# Role: chezmoi's .role, else $env:DEVENV_ROLE, else desktop (the Windows role).
$script:DoctorRole = ''
if (Get-Command chezmoi -ErrorAction SilentlyContinue) {
    try { $script:DoctorRole = "$(chezmoi execute-template '{{ .role }}' 2>$null)".Trim() } catch { $script:DoctorRole = '' }
}
if ($script:DoctorRole -notin @('server', 'desktop', 'desktop+server')) { $script:DoctorRole = "$env:DEVENV_ROLE" }
if (-not $script:DoctorRole) { $script:DoctorRole = 'desktop' }
$env:DOCTOR_ROLE = $script:DoctorRole
function Test-DoctorServerOnly {
    if ($script:DoctorRole -in @('server', 'desktop+server')) { return $null }
    return @{ Status = 'SKIP'; Reason = "server role only (role: $($script:DoctorRole))" }
}

function Register([string]$Name) { $script:DoctorChecks += $Name }

# A check returns $null on pass, or a hashtable @{ Status = 'FAIL'|'SKIP'|'WARN'; Reason = '...' }.
foreach ($f in Get-ChildItem -Path (Join-Path $script:DoctorRoot 'doctor.d') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name) {
    if ($env:DOCTOR_ONLY -and $f.Name -notlike $env:DOCTOR_ONLY) { continue }
    . $f.FullName
}

$failed = $false
foreach ($name in $script:DoctorChecks) {
    $label = $name -replace '^Check-', '' -replace '^check_', ''
    try { $r = & $name } catch { $r = @{ Status = 'FAIL'; Reason = $_.Exception.Message } }
    if ($null -eq $r) { "PASS $label" }
    elseif ($r.Status -eq 'SKIP') { "SKIP ${label}: $($r.Reason)" }
    elseif ($r.Status -eq 'WARN') { "WARN ${label}: $($r.Reason)" }
    else { "FAIL ${label}: $($r.Reason)"; $failed = $true }
}
if ($failed) { exit 1 } else { exit 0 }
