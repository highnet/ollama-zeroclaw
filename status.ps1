$ErrorActionPreference = "Stop"

$repoPath = (Resolve-Path $PSScriptRoot).Path
$drive = $repoPath.Substring(0, 1).ToLowerInvariant()
$rest = $repoPath.Substring(2).Replace('\\', '/')
$wslRepoPath = "/mnt/$drive$rest"

Write-Host "Repository: $wslRepoPath"
Write-Host "ZeroClaw home: $wslRepoPath/.zeroclaw-home"
Write-Host "Model: ollama/qwen2.5:1.5b"
Write-Host

# Check Ollama
if (wsl bash -c "curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1") {
    Write-Host "Ollama: running on 127.0.0.1:11434"
} else {
    Write-Host "Ollama: stopped"
}

# Check ZeroClaw daemon
if (wsl bash -c "curl -s --max-time 2 http://localhost:18789/api/health >/dev/null 2>&1") {
    Write-Host "ZeroClaw: running on http://127.0.0.1:18789"
} else {
    Write-Host "ZeroClaw: stopped"
}

Write-Host
$models = wsl ollama list 2>$null
if ($models) {
    Write-Host "Installed Ollama models:"
    Write-Host $models
} else {
    Write-Host "Installed Ollama models: ollama not installed"
}
