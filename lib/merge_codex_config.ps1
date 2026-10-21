# Windows modify path for ~/.codex/config.toml (Windows PowerShell 5.1 or pwsh).
# Called by modify_private_config.toml.tmpl through chezmoi's `output`: prints
# the merged config (lib/merge_codex_config.py --desktop under `uv run --script`)
# as raw UTF-8 bytes. Without uv, or when uv fails, it warns on stderr and prints
# the current file unchanged, so config.toml is never truncated.
# Usage: merge_codex_config.ps1 MERGE_PY FRAGMENT_B64 CURRENT_FILE
param([string]$MergePy, [string]$FragmentB64, [string]$Current)
$ErrorActionPreference = 'Continue'
$env:Path = (Join-Path $HOME '.local\bin') + [IO.Path]::PathSeparator + $env:Path
$stdout = [Console]::OpenStandardOutput()
function Write-Current {
    if (Test-Path -LiteralPath $Current) {
        $b = [IO.File]::ReadAllBytes($Current)
        $stdout.Write($b, 0, $b.Length)
    }
    $stdout.Flush()
}
$uv = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uv) {
    [Console]::Error.WriteLine('warning: uv missing; ~/.codex/config.toml left unchanged (re-run the bootstrap one-liner after it installs uv)')
    Write-Current
    exit 0
}
try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $uv.Source
    $psi.Arguments = "run --quiet --script `"$MergePy`" --desktop --keep-on-error --fragment-b64 $FragmentB64 --current-file `"$Current`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $ms = New-Object IO.MemoryStream
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    if (-not $p.WaitForExit(300000)) { $p.Kill(); throw 'uv timed out after 5 minutes' }
    $p.WaitForExit(); [void]$copy.Wait(60000)
    if ($p.ExitCode -eq 0 -and $ms.Length -gt 0) {
        $ms.WriteTo($stdout)
        $stdout.Flush()
        exit 0
    }
    [Console]::Error.WriteLine("warning: merging the managed Codex config failed (uv exit $($p.ExitCode)); ~/.codex/config.toml left unchanged")
} catch {
    [Console]::Error.WriteLine("warning: merging the managed Codex config failed ($_); ~/.codex/config.toml left unchanged")
}
Write-Current
exit 0
