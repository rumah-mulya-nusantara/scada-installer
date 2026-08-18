<#
.SYNOPSIS
Installer SCADA untuk lingkungan Windows.

.DESCRIPTION
Pemasang SCADA HMI Builder & Universal Gateway versi PowerShell.
Mengotomatiskan pengaturan .env dan bootstrap database.
#>

param (
    [string]$HostName = "",
    [string]$OrgName = "SCADA",
    [string]$AdminName = "Administrator",
    [string]$AdminEmail = "",
    [string]$AdminPassword = "",
    [string]$Mode = "onprem",
    [switch]$Http,
    [switch]$Https,
    [string]$ImageTag = "latest",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ROOT = (Get-Location).Path
$COMPOSE = "docker", "compose", "-f", "docker-compose.prod.yml"
$ENV_FILE = Join-Path $ROOT ".env"

if ($Https) { $Scheme = "https" } else { $Scheme = "http" }
if ($Http -and $Https) { Write-Host "Pilih salah satu: -Http atau -Https"; exit 1 }

function Write-Ok ($msg) { Write-Host "✔ $msg" -ForegroundColor Green }
function Write-Info ($msg) { Write-Host "· $msg" -ForegroundColor Cyan }
function Write-Warn ($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "✘ $msg" -ForegroundColor Red }

# ── 1. Prasyarat ─────────────────────────────────────────────────────────────
Write-Host "`n· Memeriksa prasyarat..." -ForegroundColor Cyan
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err "Docker belum terpasang."
    exit 1
}
docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Plugin 'docker compose' v2 tidak tersedia."
    exit 1
}
docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Docker daemon tidak berjalan."
    exit 1
}
$DockerVer = (docker version --format '{{.Server.Version}}')
Write-Ok "Docker $DockerVer siap"

# ── 2. Alamat server (auto-detect) ───────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($HostName)) {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -Type Unicast -PrefixOrigin Dhcp,Manual | Where-Object InterfaceAlias -notmatch "(Loopback|vEthernet)" | Select-Object -First 1).IPAddress
        if ([string]::IsNullOrWhiteSpace($ip)) { $ip = "localhost" }
        $HostName = $ip
    } catch {
        $HostName = "localhost"
    }
}

$SITE_ADDRESS = "$Scheme`://$HostName"
$WS_URL = $SITE_ADDRESS -replace "^http", "ws"

Write-Ok "Alamat server terdeteksi: $SITE_ADDRESS"

# ── 3. Akun admin ────────────────────────────────────────────────────────────
Write-Host ""
if (-not $Yes) {
    if ([string]::IsNullOrWhiteSpace($AdminEmail)) {
        $AdminEmail = Read-Host "Email admin"
    }
    if ($AdminPassword.Length -lt 8) {
        while ($AdminPassword.Length -lt 8) {
            $securePwd = Read-Host "Kata sandi admin (min. 8 karakter)" -AsSecureString
            $AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
            if ($AdminPassword.Length -lt 8) { Write-Warn "Terlalu pendek, coba lagi." }
        }
    }
} else {
    if ([string]::IsNullOrWhiteSpace($AdminEmail)) { Write-Err "-AdminEmail wajib diisi dengan -Yes"; exit 1 }
    if ($AdminPassword.Length -lt 8) { Write-Err "-AdminPassword minimal 8 karakter"; exit 1 }
}

# ── 4. Buat .env ─────────────────────────────────────────────────────────────
function Generate-RandomHex($bytes) {
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    $buffer = New-Object byte[] $bytes
    $rng.GetBytes($buffer)
    return ($buffer | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Generate-EncryptionKey() {
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    $buffer = New-Object byte[] 32
    $rng.GetBytes($buffer)
    return [Convert]::ToBase64String($buffer).Replace("+", "-").Replace("/", "_")
}

if (Test-Path $ENV_FILE) {
    Write-Warn ".env sudah ada — dipertahankan (hapus dulu jika ingin instalasi bersih)"
} else {
    Write-Info "Membangkitkan konfigurasi..."
    $SECRET_KEY = Generate-RandomHex 32
    $ENCRYPTION_KEY = Generate-EncryptionKey
    $POSTGRES_PASSWORD = Generate-RandomHex 24
    
    $COOKIE_SECURE = if ($Scheme -eq "https") { "true" } else { "false" }
    $CADDY_TLS = if ($Scheme -eq "https") { "tls internal" } else { "" }
    $EnvContent = @(
        "# Dibuat oleh install.ps1 — $DateStr",
        "DEPLOYMENT_MODE=$Mode",
        "ENVIRONMENT=production",
        "LOG_LEVEL=INFO",
        "",
        "SITE_ADDRESS=$SITE_ADDRESS",
        "PUBLIC_URL=$SITE_ADDRESS",
        "CORS_ORIGINS=$SITE_ADDRESS",
        "NEXT_PUBLIC_WS_URL=$WS_URL",
        "HTTP_PORT=80",
        "HTTPS_PORT=443",
        "CADDY_TLS=$CADDY_TLS",
        "",
        "POSTGRES_USER=scada",
        "POSTGRES_PASSWORD=$POSTGRES_PASSWORD",
        "POSTGRES_DB=scada",
        "",
        "SECRET_KEY=$SECRET_KEY",
        "ENCRYPTION_KEY=$ENCRYPTION_KEY",
        "ACCESS_TOKEN_EXPIRE_MINUTES=15",
        "REFRESH_TOKEN_EXPIRE_DAYS=30",
        "COOKIE_SECURE=$COOKIE_SECURE",
        "COOKIE_DOMAIN=",
        "",
        "# Edge agent — isi setelah buat agen di UI, lalu jalankan: .\scada.ps1 restart",
        "AGENT_ENROLLMENT_CODE=",
        "AGENT_LOG_LEVEL=INFO",
        "",
        "LICENSE_FILE=/srv/license/license.key",
        "IMAGE_TAG=$ImageTag"
    ) -join "`n"
    Set-Content -Path $ENV_FILE -Value $EnvContent -Encoding UTF8
    Write-Ok ".env dibuat"
}

$LicenseDir = Join-Path $ROOT "license"
$BackupsDir = Join-Path $ROOT "backups"
if (-not (Test-Path $LicenseDir)) { New-Item -ItemType Directory -Path $LicenseDir | Out-Null }
if (-not (Test-Path $BackupsDir)) { New-Item -ItemType Directory -Path $BackupsDir | Out-Null }
Set-Content -Path (Join-Path $LicenseDir ".gitkeep") -Value "" -Encoding UTF8

# ── 5. Tarik image ────────────────────────────────────────────────────────────
Write-Host "`n· Mengunduh image SCADA ($ImageTag)..." -ForegroundColor Cyan
& docker compose -f docker-compose.prod.yml pull
Write-Ok "Image siap"

# ── 6. Migrasi & bootstrap ────────────────────────────────────────────────────
Write-Info "Menyalakan database..."
& docker compose -f docker-compose.prod.yml up -d --wait db redis

Write-Info "Migrasi database..."
& docker compose -f docker-compose.prod.yml run --rm api alembic upgrade head

Write-Info "Mengisi data awal..."
& docker compose -f docker-compose.prod.yml run --rm api python -m app.db.seed

Write-Info "Membuat akun admin..."
$env:BOOTSTRAP_ORG_NAME = $OrgName
$env:BOOTSTRAP_ADMIN_NAME = $AdminName
$env:BOOTSTRAP_ADMIN_EMAIL = $AdminEmail
$env:BOOTSTRAP_ADMIN_PASSWORD = $AdminPassword
& docker compose -f docker-compose.prod.yml run --rm api python -m app.db.bootstrap
Remove-Item Env:\BOOTSTRAP_ORG_NAME, Env:\BOOTSTRAP_ADMIN_NAME, Env:\BOOTSTRAP_ADMIN_EMAIL, Env:\BOOTSTRAP_ADMIN_PASSWORD -ErrorAction SilentlyContinue

Write-Info "Menyalakan semua layanan..."
& docker compose -f docker-compose.prod.yml up -d

# ── 7. Selesai ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  ✔  SCADA berhasil dipasang!         ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Buka browser  →  $SITE_ADDRESS"
Write-Host "  Login email   →  $AdminEmail"
Write-Host ""
Write-Host "  Langkah selanjutnya — daftarkan edge agent:"
Write-Host "    1. Buka UI → Agen → Buat Agen Baru → salin kode (enr_xxxx)"
Write-Host "    2. Jalankan   →  .\scada.ps1 enroll enr_xxxx"
Write-Host ""
Write-Host "  Perintah berguna:"
Write-Host "    .\scada.ps1 logs       — lihat log semua service"
Write-Host "    .\scada.ps1 restart    — restart seluruh layanan"
Write-Host "    .\scada.ps1 pull       — upgrade ke versi terbaru"
Write-Host ""
