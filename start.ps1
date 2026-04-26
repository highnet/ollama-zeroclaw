$ErrorActionPreference = "Continue"

function Get-WslPath([string]$windowsPath) {
    $resolved = (Resolve-Path $windowsPath).Path
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    $rest = $resolved.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

function Wait-TcpPort([int]$Port, [int]$TimeoutSeconds = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($listening) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-PreferredWslDistro {
    $distros = @(wsl -l -q 2>$null) | Where-Object { $_ -and $_.Trim() -ne '' }
    if ($distros -contains 'Ubuntu-24.04') {
        return 'Ubuntu-24.04'
    }
    $ubuntu = $distros | Where-Object { $_ -match '^Ubuntu' } | Select-Object -First 1
    if ($ubuntu) {
        return $ubuntu.Trim()
    }
    $fallback = $distros | Where-Object { $_ -notmatch 'docker-desktop' } | Select-Object -First 1
    if ($fallback) {
        return $fallback.Trim()
    }
    return $null
}

$repoPath = (Resolve-Path $PSScriptRoot).Path
$launchScript = Get-WslPath (Join-Path $repoPath 'scripts\wsl\keep_open.sh')
$distro = Get-PreferredWslDistro
if (-not $distro) {
    throw 'No usable WSL distribution found.'
}

# Start Windows Ollama (GPU-accelerated) before WSL.
# WSL2 mirrored networking exposes localhost:11434 into WSL unchanged.
$ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
if (Test-Path $ollamaExe) {
    $running = Get-Process -Name 'ollama' -ErrorAction SilentlyContinue
    $listening = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue

    if (-not $running -and -not $listening) {
        Write-Host 'Starting Windows Ollama (GPU)...'
        Start-Process $ollamaExe -WindowStyle Hidden
        if (-not (Wait-TcpPort -Port 11434 -TimeoutSeconds 15)) {
            Write-Warning 'Windows Ollama did not open port 11434 in time. WSL fallback may be used.'
        }
    } else {
        $reason = if ($running) { "PID $($running[0].Id)" } else { 'port 11434 listening' }
        Write-Host "Windows Ollama already running ($reason)"
    }
} else {
    Write-Warning "ollama.exe not found at $ollamaExe - will use WSL CPU fallback"
}

$wtCmd = Get-Command wt.exe -ErrorAction SilentlyContinue

$runInline = $env:TERM_PROGRAM -eq 'vscode' -or $Host.Name -match 'Visual Studio Code|ConsoleHost'
if ($runInline) {
    & wsl.exe -d $distro -- bash $launchScript
} elseif ($wtCmd) {
    Start-Process wt.exe -ArgumentList @(
        '--window', 'new',
        'wsl.exe', '-d', $distro, '--',
        'bash', $launchScript
    )
} else {
    Start-Process wsl.exe -ArgumentList @(
        '-d', $distro, '--',
        'bash', $launchScript
    )
}
