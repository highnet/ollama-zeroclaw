$ErrorActionPreference = "Stop"

$repoPath = (Resolve-Path $PSScriptRoot).Path
$drive = $repoPath.Substring(0, 1).ToLowerInvariant()
$rest = $repoPath.Substring(2).Replace('\\', '/')
$wslRepoPath = "/mnt/$drive$rest"

# Stop ZeroClaw daemon and Ollama in WSL via bash pkill (run inside bash)
try { wsl bash -lc "cd '$wslRepoPath' && pkill -f 'zeroclaw' >/dev/null 2>&1 || true" } catch {}
try { wsl bash -lc "cd '$wslRepoPath' && pkill -f 'ollama' >/dev/null 2>&1 || true" } catch {}

# Clean up runtime directory
$runtimeDir = Join-Path $PSScriptRoot '.runtime'
if (Test-Path (Join-Path $runtimeDir 'zeroclaw.pid')) {
    try { Remove-Item (Join-Path $runtimeDir 'zeroclaw.pid') -Force -ErrorAction Stop } catch {}
}

Write-Host 'ZeroClaw stopped'
