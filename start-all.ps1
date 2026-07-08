#!/usr/bin/env pwsh
# Start all proxy servers and llama-swap

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$proxy = $null

$proxyArg = if ($proxy) { " --proxy $proxy" } else { "" }

function Test-Port($port) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    return $null -ne $conn
}

function Get-ProcessOnPort($port) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        $ownerPid = $conn[0].OwningProcess
        return Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    }
    return $null
}

function Stop-PortOwner($port, $name) {
    $proc = Get-ProcessOnPort $port
    if ($proc) {
        Write-Host "    Port $port is used by PID $($proc.Id) ($($proc.Name))" -ForegroundColor Yellow
        $confirm = Read-Host "    Kill it? (y/N)"
        if ($confirm -eq "y" -or $confirm -eq "Y") {
            Stop-Process -Id $proc.Id -Force
            Start-Sleep -Milliseconds 500
            Write-Host "    Killed." -ForegroundColor Green
            return $true
        } else {
            Write-Host "    Skipping $name." -ForegroundColor Red
            return $false
        }
    }
    return $true
}

Write-Host "Checking ports..." -ForegroundColor Cyan

$ports = @(6446, 18632, 8788, 8080)
$blocked = @()
foreach ($port in $ports) {
    if (Test-Port $port) {
        $proc = Get-ProcessOnPort $port
        $info = if ($proc) { "PID $($proc.Id) ($($proc.Name))" } else { "unknown" }
        Write-Host "  :$port - OCCUPIED by $info" -ForegroundColor Yellow
        $blocked += $port
    } else {
        Write-Host "  :$port - free" -ForegroundColor DarkGray
    }
}

if ($blocked.Count -gt 0) {
    Write-Host "`nSome ports are occupied." -ForegroundColor Yellow
    $answer = Read-Host "Kill occupied processes and continue? (y/N)"
    if ($answer -ne "y" -and $answer -ne "Y") {
        Write-Host "Aborted." -ForegroundColor Red
        exit 1
    }
    foreach ($port in $blocked) {
        Stop-PortOwner $port ""
    }
}

Write-Host "`nStarting proxy servers..." -ForegroundColor Cyan

# Start opencode-free-proxy (port 6446)
Write-Host "  [1/3] opencode-free-proxy on :6446" -ForegroundColor Green
$proc1 = Start-Process -FilePath "python" `
    -ArgumentList "server.py --port 6446 --host 127.0.0.1$proxyArg" `
    -WorkingDirectory "$root\opencode-free-proxy" `
    -PassThru -WindowStyle Hidden

# Start deepseek-free-api (port 18632) - requires Python 3.10 for wasmer
$dsPython = "py -3.10"
Write-Host "  [2/3] deepseek-free-api on :18632" -ForegroundColor Green
$dsAuthFile = "$env:USERPROFILE\.deepseek-free-api\auth.json"
if (-not (Test-Path $dsAuthFile)) {
    Write-Host "    Auth not found. Starting login..." -ForegroundColor Yellow
    Write-Host "    A browser window will open. Log in to DeepSeek." -ForegroundColor Yellow
    Push-Location "$root\deepseek-free-api"
    & py -3.10 server.py --login
    Pop-Location
}
$proc2 = Start-Process -FilePath "py" `
    -ArgumentList "-3.10 server.py --port 18632 --host 127.0.0.1$proxyArg" `
    -WorkingDirectory "$root\deepseek-free-api" `
    -PassThru -WindowStyle Hidden

# Start mimo-free-proxy (port 8788)
Write-Host "  [3/3] mimo-free-proxy on :8788" -ForegroundColor Green
$proc3 = Start-Process -FilePath "python" `
    -ArgumentList "server.py --port 8788 --host 127.0.0.1$proxyArg" `
    -WorkingDirectory "$root\mimo-free-proxy" `
    -PassThru -WindowStyle Hidden

Write-Host "`nWaiting for servers to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Check which ports are listening
$running = @()
$failed = @()
if (Test-Port 6446) { $running += "opencode-free-proxy" } else { $failed += "opencode-free-proxy" }
if (Test-Port 18632) { $running += "deepseek-free-api" } else { $failed += "deepseek-free-api" }
if (Test-Port 8788) { $running += "mimo-free-proxy" } else { $failed += "mimo-free-proxy" }

if ($failed.Count -gt 0) {
    Write-Host "WARNING: Failed to start: $($failed -join ', ')" -ForegroundColor Red
    Write-Host "Check logs in $root\*.log and $root\*.err" -ForegroundColor Yellow
}

Write-Host "Running: $($running -join ', ')" -ForegroundColor Green

# Find llama-swap binary
$binary = Get-ChildItem "$root\llama-swap.exe\llama-swap.exe" -ErrorAction SilentlyContinue
if (-not $binary) {
    $binary = Get-ChildItem "$root\llama-swap.exe" -File -ErrorAction SilentlyContinue
}
if (-not $binary) {
    $binary = Get-ChildItem "$root\llama-swap_*_windows_amd64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $binary) {
    $binary = Get-ChildItem "$root\build\llama-swap-windows-amd64.exe" -ErrorAction SilentlyContinue
}
if (-not $binary) {
    Write-Host "ERROR: llama-swap binary not found." -ForegroundColor Red
    exit 1
}

# Start llama-swap
Write-Host "`nStarting llama-swap on :8080..." -ForegroundColor Cyan
Write-Host "Config: $root\config.yaml" -ForegroundColor DarkGray
Write-Host "Press Ctrl+C to stop all servers`n" -ForegroundColor DarkGray

try {
    & "$($binary.FullName)" --config "$root\config.yaml" --listen localhost:8080
} finally {
    Write-Host "`nStopping all servers..." -ForegroundColor Yellow
    Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "Done." -ForegroundColor Green
}
