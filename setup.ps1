$ErrorActionPreference = "Stop"

$repoPath = (Resolve-Path $PSScriptRoot).Path
$drive = $repoPath.Substring(0, 1).ToLowerInvariant()
$rest = $repoPath.Substring(2).Replace('\', '/')
$wslRepoPath = "/mnt/$drive$rest"

if (-not $wslRepoPath) {
    throw "Failed to resolve the repository path inside WSL. Make sure WSL is installed and available."
}

wsl bash -lc "cd '$wslRepoPath' && ./scripts/wsl/setup.sh"
