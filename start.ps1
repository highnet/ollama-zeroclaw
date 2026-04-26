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

function Get-OllamaStartupEnvironment {
    $envOverrides = @{
        'OLLAMA_HOST' = 'http://127.0.0.1:11434'
    }

    try {
        $amdGpu = Get-CimInstance Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -match 'AMD|Radeon' } |
            Select-Object -First 1
        if ($amdGpu) {
            [System.Environment]::SetEnvironmentVariable('OLLAMA_VULKAN', '1', 'User')
            $envOverrides['OLLAMA_VULKAN'] = '1'
        }
    } catch {
    }

    return $envOverrides
}

function Start-OllamaProcess([string]$OllamaExe, [hashtable]$EnvironmentOverrides) {
    $serveScriptParts = @()
    foreach ($entry in $EnvironmentOverrides.GetEnumerator()) {
        $escapedValue = $entry.Value.Replace("'", "''")
        $serveScriptParts += "`$env:$($entry.Key) = '$escapedValue'"
    }

    $escapedExe = $OllamaExe.Replace("'", "''")
    $serveScriptParts += "& '$escapedExe' serve"
    $serveScript = $serveScriptParts -join '; '

    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command', $serveScript
    )
}

function Stop-WindowsOllama([int]$Port = 11434) {
    Get-Process -Name 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if (-not $listening) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Start-WindowsOllamaProxy([string]$RepoPath, [int]$ListenPort = 11435) {
    $existing = Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Windows Ollama proxy already running on port $ListenPort"
        return
    }

    $proxyScript = Join-Path $RepoPath 'scripts\windows\localhost_proxy.py'
    if (-not (Test-Path $proxyScript)) {
        Write-Warning "Proxy script not found at $proxyScript"
        return
    }

    $pythonExe = Join-Path $RepoPath '.venv\Scripts\python.exe'
    $command = $null
    $args = @()
    if (Test-Path $pythonExe) {
        $command = $pythonExe
        $args = @(
            $proxyScript,
            '--listen-host', '0.0.0.0',
            '--listen-port', "$ListenPort",
            '--target-host', '127.0.0.1',
            '--target-port', '11434'
        )
    } else {
        $py = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($py) {
            $command = $py.Source
            $args = @(
                '-3',
                $proxyScript,
                '--listen-host', '0.0.0.0',
                '--listen-port', "$ListenPort",
                '--target-host', '127.0.0.1',
                '--target-port', '11434'
            )
        }
    }

    if (-not $command) {
        Write-Warning 'No Python interpreter available to start the Windows Ollama proxy.'
        return
    }

    Write-Host "Starting Windows Ollama proxy on port $ListenPort..."
    Start-Process -FilePath $command -ArgumentList $args -WindowStyle Hidden
    if (-not (Wait-TcpPort -Port $ListenPort -TimeoutSeconds 5)) {
        Write-Warning "Windows Ollama proxy did not open port $ListenPort in time."
    }
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
    $ollamaEnv = Get-OllamaStartupEnvironment
    $needsAmdGpuRestart = $ollamaEnv.ContainsKey('OLLAMA_VULKAN')
    $running = Get-Process -Name 'ollama' -ErrorAction SilentlyContinue
    $listening = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue

    if ($needsAmdGpuRestart -and ($running -or $listening)) {
        Write-Host 'Restarting Windows Ollama with Vulkan enabled...'
        if (-not (Stop-WindowsOllama)) {
            Write-Warning 'Windows Ollama did not fully stop before restart.'
        }
        Start-OllamaProcess -OllamaExe $ollamaExe -EnvironmentOverrides $ollamaEnv
        if (-not (Wait-TcpPort -Port 11434 -TimeoutSeconds 15)) {
            Write-Warning 'Windows Ollama did not open port 11434 in time. WSL fallback may be used.'
        }
    } elseif (-not $running -and -not $listening) {
        Write-Host 'Starting Windows Ollama (GPU)...'
        Start-OllamaProcess -OllamaExe $ollamaExe -EnvironmentOverrides $ollamaEnv
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

Start-WindowsOllamaProxy -RepoPath $repoPath

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
