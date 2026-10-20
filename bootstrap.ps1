# Bootstrap (Windows Desktop): one command from a fresh machine to a
# Doctor-checked environment. PowerShell twin of bootstrap.sh.
#
#   irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex
#   pwsh -File bootstrap.ps1 [--source REPO] [--role ROLE] [--ci]
#
# 1. Installs chezmoi and uv into ~/.local/bin if missing (and puts that dir on
#    the user PATH).
# 2. Clones REPO (a local path, a git URL or owner/repo on GitHub; default
#    yyds-tsai-dev/develop-env-settings) into chezmoi's source dir unless it is
#    already there, then runs `chezmoi init`.
# 3. Hold file (~/.config/develop-env/hold): only the machine-local steps run.
# 4. Resolves the Version lock (a failure keeps the committed lock).
# 5. Backs up every existing target `chezmoi status` reports as changing into
#    ~/.dotfiles-backup-<YYYYmmdd-HHMMSS>/; if `chezmoi status` fails, apply is
#    skipped.
# 6. chezmoi apply, bin/machine-local (through Git Bash), bin/doctor.ps1.
#    Exit status: 1 if apply failed or was skipped, else Doctor's.
#
# --role: desktop (the only Windows role; Server use goes through WSL2, where
#   bootstrap.sh runs). Without it chezmoi asks once. --ci: CI=true
#   (non-interactive) and `bin/doctor.ps1 -Ci`. -Source/-Role/-Ci work too.
# git is required: when it is missing, the script prints the winget command and
# exits 1. Never elevates: commands that need admin rights are printed.
# The NFS-home and long-running-process warnings of bootstrap.sh are Linux
# concerns and are not repeated here.
# The body is one function so that `irm | iex` has read the whole script before
# anything runs (iex cannot bind a script-level param block, so arguments are
# parsed by hand).

function Invoke-DevenvBootstrap([string[]]$Argv) {
    $ErrorActionPreference = 'Stop'
    $src = 'yyds-tsai-dev/develop-env-settings'
    $srcGiven = $false
    $role = ''
    $ci = $false
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        $a = $Argv[$i]
        switch -Regex ($a) {
            '^(--source|-Source)$' {
                if ($i + 1 -ge $Argv.Count) { Write-Error 'error: --source needs a value' -ErrorAction Continue; $script:DevenvRc = 2; return }
                $src = $Argv[++$i]; $srcGiven = $true; continue
            }
            '^--source=' { $src = $a.Substring(9); $srcGiven = $true; continue }
            '^(--role|-Role)$' {
                if ($i + 1 -ge $Argv.Count) { Write-Error 'error: --role needs a value' -ErrorAction Continue; $script:DevenvRc = 2; return }
                $role = $Argv[++$i]; continue
            }
            '^--role=' { $role = $a.Substring(7); continue }
            '^(--ci|-Ci)$' { $ci = $true; continue }
            '^(-h|--help|-Help)$' { 'usage: bootstrap.ps1 [--source REPO] [--role ROLE] [--ci]'; $script:DevenvRc = 0; return }
            default { Write-Error "error: unknown argument: $a" -ErrorAction Continue; $script:DevenvRc = 2; return }
        }
    }
    if ($ci) { $env:CI = 'true' }
    if ((Test-Path variable:IsWindows) -and -not $IsWindows) {
        Write-Error 'error: bootstrap.ps1 is for Windows; use bootstrap.sh on Linux and macOS' -ErrorAction Continue
        $script:DevenvRc = 1; return
    }

    $bin = Join-Path $HOME '.local\bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $env:Path = "$bin;$env:Path"
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ((($userPath -split ';') | Where-Object { $_ -eq $bin }).Count -eq 0) {
        [Environment]::SetEnvironmentVariable('Path', ((@($userPath, $bin) | Where-Object { $_ }) -join ';'), 'User')
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error 'error: git is required; run: winget install --id Git.Git -e --scope user' -ErrorAction Continue
        $script:DevenvRc = 1; return
    }

    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { $cz = 'windows-amd64'; $uvt = 'x86_64-pc-windows-msvc' }
        'ARM64' { $cz = 'windows-arm64'; $uvt = 'aarch64-pc-windows-msvc' }
        default { Write-Error "error: unsupported architecture $env:PROCESSOR_ARCHITECTURE" -ErrorAction Continue; $script:DevenvRc = 1; return }
    }

    try {
        if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
            "installing chezmoi into $bin"
            $tmpExe = Join-Path $bin 'chezmoi.exe.tmp'
            Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/twpayne/chezmoi/releases/latest/download/chezmoi-$cz.exe" -OutFile $tmpExe
            Move-Item -Force $tmpExe (Join-Path $bin 'chezmoi.exe')
        }
        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
            "installing uv into $bin"
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('uv-' + [guid]::NewGuid())
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            try {
                $zip = Join-Path $tmp 'uv.zip'
                Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/astral-sh/uv/releases/latest/download/uv-$uvt.zip" -OutFile $zip
                Expand-Archive -Path $zip -DestinationPath $tmp -Force
                foreach ($f in 'uv.exe', 'uvx.exe', 'uvw.exe') {
                    $p = Get-ChildItem -Path $tmp -Recurse -Filter $f | Select-Object -First 1
                    if ($p) { Move-Item -Force $p.FullName (Join-Path $bin $f) }
                }
            } finally {
                Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Error "error: download failed: $_" -ErrorAction Continue
        $script:DevenvRc = 1; return
    }
    $ErrorActionPreference = 'Continue'

    $wt = Join-Path $HOME '.local\share\chezmoi'
    if ($src -match '^(/|\./|\.\./|[A-Za-z]:[\\/]|\\\\)' -or $src -match '://' -or $src -match '@.*:') { $url = $src }
    elseif ($src -match '/') { if (Test-Path $src) { $url = $src } else { $url = "https://github.com/$src.git" } }
    else { $url = $src }
    if (-not (Test-Path (Join-Path $wt '.git'))) {
        "cloning $url into $wt"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $wt) | Out-Null
        git clone -q $url $wt
        if ($LASTEXITCODE -ne 0) { Write-Error "error: git clone $url failed" -ErrorAction Continue; $script:DevenvRc = 1; return }
    } elseif ($srcGiven) {
        $origin = git -C $wt remote get-url origin 2>$null
        if ($origin -ne $url) {
            Write-Warning "reusing existing clone $wt whose origin is $(if ($origin) { $origin } else { 'unset' }), not $url"
        }
    }

    $initArgs = @('init')
    if ($ci) { $initArgs += '--no-tty' }
    if ($role) { $initArgs += @('--promptChoice', "role=$role") }
    & chezmoi @initArgs
    if ($LASTEXITCODE -ne 0) { $script:DevenvRc = 1; return }
    $wt = chezmoi execute-template '{{ .chezmoi.workingTree }}'
    if ($LASTEXITCODE -ne 0 -or -not $wt) { $script:DevenvRc = 1; return }

    # Git Bash (not WSL's bash.exe) runs the bash machine-local steps.
    $bash = $null
    $gitExe = (Get-Command git).Source
    foreach ($c in @((Join-Path (Split-Path -Parent (Split-Path -Parent $gitExe)) 'bin\bash.exe'),
                     (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
                     (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))) {
        if ($c -and (Test-Path $c)) { $bash = $c; break }
    }
    $machineLocal = {
        if ($bash) {
            $mlArgs = @(($wt -replace '\\', '/') + '/bin/machine-local')
            if ($ci) { $mlArgs += '--ci' }
            & $bash @mlArgs
        } else {
            Write-Warning 'Git Bash not found; machine-local steps (known_hosts, SSH key) skipped'
        }
    }

    $hold = Join-Path $HOME '.config\develop-env\hold'
    if ((Test-Path $hold) -or ((chezmoi execute-template '{{ .hold }}' 2>$null) -eq 'true')) {
        'hold file present: not applying dotfiles'
        & $machineLocal
        $script:DevenvRc = 0; return
    }

    'resolving the version lock'
    uv run --script (Join-Path $wt 'lib\resolve_versions.py') `
        --manifest (Join-Path $wt 'home\.chezmoidata\manifest.yaml') `
        --lock (Join-Path $wt 'home\.chezmoidata\versions.yaml')
    if ($LASTEXITCODE -ne 0) { Write-Warning 'version lock resolve failed; keeping the committed lock' }

    $applyRc = 0
    $status = chezmoi status --exclude=scripts 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "chezmoi status failed, so nothing could be backed up: $status"
        Write-Warning 'skipping chezmoi apply: no file was written'
        $applyRc = 1
    } else {
        $dir = Join-Path $HOME (".dotfiles-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $n = 0
        foreach ($line in @($status)) {
            $line = "$line"
            if ($line.Length -lt 4 -or $line[1] -eq ' ') { continue }
            $rel = $line.Substring(3)
            $path = Join-Path $HOME $rel
            if (-not (Test-Path -PathType Leaf $path)) { continue }
            $dest = Join-Path $dir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            try { Copy-Item -Force $path $dest; $n++ } catch { Write-Warning "could not back up ${path}: $_" }
        }
        if ($n -gt 0) { "backed up $n file(s) that apply will change to $dir" }
        else { 'nothing to back up: apply changes no existing file' }
        if ($ci) { chezmoi apply --force --no-tty } else { chezmoi apply --force }
        $applyRc = $LASTEXITCODE
        if ($applyRc -ne 0) { Write-Warning "dotfiles not applied (exit $applyRc)" }
    }

    & $machineLocal

    $doctor = Join-Path $wt 'bin\doctor.ps1'
    if ($ci) { & $doctor -Ci } else { & $doctor }
    $doctorRc = $LASTEXITCODE
    if ($applyRc -ne 0) { $script:DevenvRc = 1; return }
    $script:DevenvRc = $doctorRc; return
}

# The function sets $script:DevenvRc. A script file exits with it; under
# `irm | iex` exit would close the person's shell, so it is only reported.
$script:DevenvRc = 0
Invoke-DevenvBootstrap $args
if ($MyInvocation.MyCommand.Path) { exit $script:DevenvRc }
if ($script:DevenvRc -ne 0) { Write-Warning "bootstrap finished with exit status $script:DevenvRc" }
