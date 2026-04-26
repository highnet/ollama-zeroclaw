$ErrorActionPreference = "Stop"

$repoPath = (Resolve-Path $PSScriptRoot).Path
$drive = $repoPath.Substring(0, 1).ToLowerInvariant()
$rest = $repoPath.Substring(2).Replace('\', '/')
$wslRepoPath = "/mnt/$drive$rest"

$envFile = Join-Path $repoPath '.env'
$model = 'qwen2.5:1.5b'
if (Test-Path $envFile) {
    $line = Get-Content $envFile | Where-Object { $_ -match '^ZEROCLAW_MODEL=' } | Select-Object -First 1
    if ($line) {
        $value = ($line -split '=', 2)[1].Trim()
        if ($value.StartsWith('ollama/')) {
            $value = $value.Substring(7)
        }
        if ($value) {
            $model = $value
        }
    }
}

Write-Host "Repository: $wslRepoPath"
Write-Host "ZeroClaw home: $wslRepoPath/.zeroclaw-home"
Write-Host "Model: $model"
Write-Host

# Check Ollama
wsl bash -c "curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1"
if ($LASTEXITCODE -eq 0) {
    Write-Host "Ollama: running on 127.0.0.1:11434"
} else {
    Write-Host "Ollama: stopped"
}

# Check ZeroClaw daemon
wsl bash -c "curl -s --max-time 2 http://localhost:18789/api/health >/dev/null 2>&1"
if ($LASTEXITCODE -eq 0) {
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
