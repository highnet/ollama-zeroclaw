$ErrorActionPreference = "Stop"

$repoPath = (Resolve-Path $PSScriptRoot).Path
$drive = $repoPath.Substring(0, 1).ToLowerInvariant()
$rest = $repoPath.Substring(2).Replace('\\', '/')
$wslRepoPath = "/mnt/$drive$rest"

wsl bash -lc "cd '$wslRepoPath' && ./scripts/wsl/status.sh"
