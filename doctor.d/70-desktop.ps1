# Windows Desktop checks (PowerShell twin of 70-desktop.sh).
# winget-installed apps WARN when missing: a package without a user-scope
# installer needs the elevated command 70-desktop printed. -Ci: the
# Secret-backed ~/.ssh/config check is SKIP.

function Test-DesktopApp([string]$Cmd, [string[]]$Paths) {
    if (Get-Command $Cmd -ErrorAction SilentlyContinue) { return $true }
    foreach ($p in $Paths) { if ($p -and (Test-Path $p)) { return $true } }
    return $false
}

function check_git {
    if (Get-Command git -ErrorAction SilentlyContinue) { return $null }
    return @{ Status = 'FAIL'; Reason = 'git missing (winget install --id Git.Git -e --scope user)' }
}
Register 'check_git'

function check_gh {
    if (Test-DesktopApp 'gh' @((Join-Path "$env:ProgramFiles" 'GitHub CLI\gh.exe'))) { return $null }
    return @{ Status = 'WARN'; Reason = 'gh missing (winget install --id GitHub.cli -e)' }
}
Register 'check_gh'

function check_wezterm {
    if (Test-DesktopApp 'wezterm' @((Join-Path "$env:ProgramFiles" 'WezTerm\wezterm.exe'), (Join-Path "$env:LOCALAPPDATA" 'Programs\WezTerm\wezterm.exe'))) { return $null }
    return @{ Status = 'WARN'; Reason = 'WezTerm missing (winget install --id wez.wezterm -e)' }
}
Register 'check_wezterm'

function check_vscode {
    if (Test-DesktopApp 'code' @((Join-Path "$env:LOCALAPPDATA" 'Programs\Microsoft VS Code\Code.exe'), (Join-Path "$env:ProgramFiles" 'Microsoft VS Code\Code.exe'))) { return $null }
    return @{ Status = 'WARN'; Reason = 'VS Code missing (winget install --id Microsoft.VisualStudioCode -e --scope user)' }
}
Register 'check_vscode'

function check_nerd_font {
    foreach ($d in @((Join-Path "$env:LOCALAPPDATA" 'Microsoft\Windows\Fonts'), (Join-Path "$env:WINDIR" 'Fonts'))) {
        if (Test-Path (Join-Path $d 'JetBrainsMonoNerdFont-Regular.ttf')) { return $null }
    }
    return @{ Status = 'FAIL'; Reason = 'JetBrainsMono Nerd Font not in the user font dir (rerun apply)' }
}
Register 'check_nerd_font'

function check_wezterm_config {
    if (Test-Path (Join-Path $HOME '.wezterm.lua')) { return $null }
    return @{ Status = 'FAIL'; Reason = '~/.wezterm.lua missing (rerun apply)' }
}
Register 'check_wezterm_config'

function check_ssh_config {
    if ($script:DoctorCi) { return @{ Status = 'SKIP'; Reason = 'secret check skipped in -Ci' } }
    $f = Join-Path $HOME '.ssh\config'
    if ((Test-Path $f) -and ((Get-Item $f).Length -gt 0)) { return $null }
    return @{ Status = 'FAIL'; Reason = '~/.ssh/config missing (unlock Bitwarden and apply again)' }
}
Register 'check_ssh_config'
