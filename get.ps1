<#
.SYNOPSIS
Bootstrap installer SCADA untuk Windows.

.DESCRIPTION
Mengunduh file-file yang dibutuhkan (docker-compose, install.ps1, scada.ps1, Caddyfile)
lalu mengeksekusi install.ps1 secara otomatis.

.EXAMPLE
irm https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-ruanglab/main/get.ps1 | iex
#>

$ErrorActionPreference = "Stop"

$REPO = "rumah-mulya-nusantara/scada-installer"
$BRANCH = "main"
$RAW = "https://raw.githubusercontent.com/$REPO/$BRANCH"

# Gunakan folder saat ini. Jika bukan di dalam folder 'scada', buatkan foldernya.
$INSTALL_DIR = (Get-Location).Path
$FolderName = Split-Path $INSTALL_DIR -Leaf
if ($FolderName -ne "scada") {
    $INSTALL_DIR = Join-Path $INSTALL_DIR "scada"
    if (-not (Test-Path $INSTALL_DIR)) {
        New-Item -ItemType Directory -Path $INSTALL_DIR | Out-Null
    }
}

Set-Location $INSTALL_DIR

Write-Host ""
Write-Host "· SCADA — Installer bootstrap (Windows)" -ForegroundColor Cyan
Write-Host "· Direktori instalasi: $INSTALL_DIR" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "✘ Docker belum terpasang. Instal Docker Desktop dari https://docs.docker.com/desktop/install/windows-install/" -ForegroundColor Red
    exit 1
}

# Pastikan folder infra/caddy ada
$CaddyDir = Join-Path $INSTALL_DIR "infra\caddy"
if (-not (Test-Path $CaddyDir)) {
    New-Item -ItemType Directory -Path $CaddyDir -Force | Out-Null
}

Write-Host "· Mengunduh file instalasi..." -ForegroundColor Cyan

function Download-File ($Url, $Destination) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } catch {
        Write-Host "✘ Gagal mengunduh $Url" -ForegroundColor Red
        exit 1
    }
}

Download-File "$RAW/docker-compose.prod.yml" (Join-Path $INSTALL_DIR "docker-compose.prod.yml")
Download-File "$RAW/install.ps1"             (Join-Path $INSTALL_DIR "install.ps1")
Download-File "$RAW/scada.ps1"               (Join-Path $INSTALL_DIR "scada.ps1")
Download-File "$RAW/infra/caddy/Caddyfile"   (Join-Path $CaddyDir "Caddyfile")

Write-Host "✔ File berhasil diunduh ke $INSTALL_DIR" -ForegroundColor Green

Write-Host "`n· Memulai instalasi..." -ForegroundColor Cyan
& .\install.ps1 -Http
