#Requires -Version 5.1
<#
.SYNOPSIS
Pemasang SCADA HMI Builder & Universal Gateway untuk Windows — satu berkas, satu perintah.

.DESCRIPTION
    irm https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.ps1 | iex

Non-interaktif (lewat environment, karena `iex` tidak bisa menerima parameter):

    $env:SCADA_ADMIN_EMAIL = 'a@b.c'
    $env:SCADA_ADMIN_PASSWORD = 'Rahasia123'
    $env:SCADA_YES = '1'
    irm https://raw.githubusercontent.com/.../install.ps1 | iex
#>
param(
    [string]$Dir           = $env:SCADA_DIR,
    [string]$HostAddress   = $env:SCADA_HOST,
    [int]   $Port          = 0,
    [string]$OrgName       = $env:SCADA_ORG,
    [string]$AdminName     = $env:SCADA_ADMIN_NAME,
    [string]$AdminEmail    = $env:SCADA_ADMIN_EMAIL,
    [string]$AdminPassword = $env:SCADA_ADMIN_PASSWORD,
    [string]$ImageTag      = $env:SCADA_TAG,
    # Alamat portal aktivasi vendor. Hanya ditampilkan sebagai tautan di halaman
    # Lisensi; server ini tidak pernah menghubunginya. Tidak diisi = pakai
    # $ScadaDefaultPortalUrl di bawah; isi `off` untuk menghilangkan tautannya.
    [string]$LicensePortalUrl = $env:SCADA_LICENSE_PORTAL_URL,
    [string]$AutoUpdate    = $env:SCADA_AUTO_UPDATE,
    [string]$UpdateAt      = $env:SCADA_UPDATE_AT,
    [switch]$Https,
    [switch]$NoDockerInstall,
    [switch]$Yes,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ScadaVersion = '2.1.2'

# Alamat portal aktivasi lisensi. Bawaan produk, bukan bawaan installer: nilai
# ini ikut ke setiap OS dan ke setiap instalasi yang di-upgrade, jadi pemasang
# tidak perlu mengingat env var apa pun. Alamatnya cuma ditampilkan sebagai
# tautan di halaman Lisensi — server ini tidak pernah menghubunginya.
# Menimpanya:   $env:SCADA_LICENSE_PORTAL_URL = '<url>'
# Mematikannya: $env:SCADA_LICENSE_PORTAL_URL = 'off'
$ScadaDefaultPortalUrl = 'https://script.google.com/macros/s/AKfycbzu97PwuFyUHex8xy7_QIkfxXsWkNpIS7WAIqFU0uKjWkmN5_HZjOA0kAmHZD0j9trH/exec'

# PowerShell dan cmd.exe menghapus variabel yang diisi string kosong, jadi di
# sana "kosong" tidak bisa dibedakan dari "tidak diisi" — dan "tidak diisi"
# harus jatuh ke bawaan di atas. Karena itu mematikan portal butuh kata kunci.
function Normalize-PortalUrl ([string]$Value) {
    if (-not $Value) { return '' }
    if ($Value.Trim().ToLowerInvariant() -in @('off', 'none', 'no', '-', 'false')) { return '' }
    return $Value.Trim()
}

# Override yang eksplisit boleh menimpa alamat yang sudah tersimpan di .env;
# tanpa penanda ini, alamat yang pelanggan atur sendiri lewat `scada portal`
# akan terhapus setiap kali installer dijalankan lagi.
$PortalExplicit = [bool]$LicensePortalUrl
if (-not $LicensePortalUrl) { $LicensePortalUrl = $ScadaDefaultPortalUrl }
$LicensePortalUrl = Normalize-PortalUrl $LicensePortalUrl

if (-not $Dir)       { $Dir       = Join-Path $env:USERPROFILE 'scada' }
if (-not $OrgName)   { $OrgName   = 'SCADA' }
if (-not $AdminName) { $AdminName = 'Administrator' }
if (-not $ImageTag)  { $ImageTag  = 'latest' }
if (-not $UpdateAt)  { $UpdateAt  = '02:30' }
if ($Port -eq 0 -and $env:SCADA_PORT) { $Port = [int]$env:SCADA_PORT }
if ($env:SCADA_YES -eq '1') { $Yes = $true }

function Write-Ok    ($m) { Write-Host "✔ $m" -ForegroundColor Green }
function Write-Info  ($m) { Write-Host "· $m" -ForegroundColor Cyan }
function Write-Warn2 ($m) { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Err2  ($m) { Write-Host "✘ $m" -ForegroundColor Red }
function Write-Step  ($m) { Write-Host "`n$m" -ForegroundColor White }
function Die         ($m) { Write-Err2 $m; exit 1 }

function Confirm-Action ($prompt) {
    if ($Yes) { return $true }
    $r = Read-Host "$prompt (y/N)"
    return ($r -match '^(y|ya)')
}

# ── Penulisan berkas ─────────────────────────────────────────────────────────
# Docker Compose dan Caddy membaca berkas ini apa adanya: BOM dari
# Set-Content -Encoding UTF8 di PowerShell 5 dan akhiran CRLF sama-sama
# membuat nilai .env terbaca salah.
function Save-Text ([string]$Path, [string]$Text) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lf = $Text -replace "`r`n", "`n"
    if (-not $lf.EndsWith("`n")) { $lf += "`n" }
    [System.IO.File]::WriteAllText($Path, $lf, $utf8NoBom)
}

function Get-EnvLine ([string]$Path, [string]$Key) {
    if (-not (Test-Path $Path)) { return $null }
    $line = Select-String -Path $Path -Pattern "^$Key=" | Select-Object -First 1
    if ($null -eq $line) { return $null }
    return $line.Line.Substring($Key.Length + 1)
}

function Set-EnvLine ([string]$Path, [string]$Key, [string]$Value) {
    $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    # `$` punya arti khusus di bagian pengganti -replace ($1, $&), jadi sebuah
    # URL yang memuatnya akan tertulis rusak tanpa digandakan lebih dulu.
    $safe = "$Key=$Value".Replace('$', '$$')
    $pat  = '(?m)^' + [Regex]::Escape($Key) + '=.*$'
    if ($text -match $pat) {
        $text = $text -replace $pat, $safe
    } else {
        $text = $text.TrimEnd("`n") + "`n$Key=$Value`n"
    }
    Save-Text $Path $text
}

function New-HexKey ([int]$Bytes) {
    $buf = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($buf)
    return (($buf | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-UrlSafeKey ([int]$Bytes) {
    $buf = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($buf)
    return ([Convert]::ToBase64String($buf).Replace('+', '-').Replace('/', '_'))
}

function Get-LocalIPAddress {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
              Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and
                             $_.InterfaceAlias -notmatch '(Loopback|vEthernet|WSL|Docker)' } |
              Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    } catch { }
    return 'localhost'
}

function Test-PortBusy ([int]$P) {
    $client = New-Object System.Net.Sockets.TcpClient
    try   { $client.Connect('127.0.0.1', $P); $client.Close(); return $true }
    catch { return $false }
}

# ── Docker ───────────────────────────────────────────────────────────────────
function Test-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Start-DockerDesktop {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\Docker Desktop.exe')
    )
    foreach ($exe in $candidates) {
        if (Test-Path $exe) {
            Write-Info 'Menyalakan Docker Desktop...'
            Start-Process $exe | Out-Null
            return $true
        }
    }
    return $false
}

function Wait-Docker ([int]$Seconds = 240) {
    Write-Host '· Menunggu Docker siap' -ForegroundColor Cyan -NoNewline
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerReady) { Write-Host ''; return $true }
        Start-Sleep -Seconds 3
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    return $false
}

function Install-Docker {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die 'Docker Desktop belum terpasang dan winget tidak tersedia. Pasang manual: https://www.docker.com/products/docker-desktop/'
    }
    Write-Info 'Memasang Docker Desktop lewat winget (izinkan permintaan UAC)...'
    & winget install --id Docker.DockerDesktop -e --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Die "winget gagal (kode $LASTEXITCODE). Pasang Docker Desktop manual lalu ulangi perintah ini."
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Initialize-Docker {
    Write-Step '1/7  Docker'
    if (Test-DockerReady) {
        Write-Ok "Docker $(& docker version --format '{{.Server.Version}}') siap"
        return
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        if ($NoDockerInstall) { Die 'Docker belum terpasang. https://www.docker.com/products/docker-desktop/' }
        if (-not (Confirm-Action 'Docker Desktop belum terpasang. Pasang sekarang?')) { Die 'Dibatalkan.' }
        Install-Docker
    }
    if (-not (Start-DockerDesktop)) {
        Die 'Docker terpasang tetapi Docker Desktop tidak ditemukan. Nyalakan manual lalu ulangi. Bila baru saja dipasang, mungkin perlu restart Windows.'
    }
    if (-not (Wait-Docker)) {
        Die 'Docker Desktop belum siap. Selesaikan penyiapan awalnya (mungkin perlu restart Windows), lalu ulangi perintah ini.'
    }
    & docker compose version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "Plugin 'docker compose' v2 tidak tersedia. Perbarui Docker Desktop." }
    Write-Ok "Docker $(& docker version --format '{{.Server.Version}}') siap"
}

function Invoke-Compose {
    & docker compose -f 'docker-compose.prod.yml' @args
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($args -join ' ') gagal (kode $LASTEXITCODE)" }
}

# Probe yang BOLEH gagal harus lewat sini. Dengan $ErrorActionPreference =
# 'Stop', Windows PowerShell 5.1 mengubah stderr perintah native menjadi galat
# terminating, dan `2>$null` tidak menahannya (PowerShell#4002) — satu baris
# `docker ... 2>$null` yang gagal mematikan seluruh pemasang. Perintah dijalankan
# di dalam fungsi ini supaya $ErrorActionPreference lokal benar-benar berlaku
# untuknya; scriptblock dari pemanggil tidak akan ikut.
function Invoke-DockerQuiet {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$DockerArgs)
    $prevEap = $ErrorActionPreference
    $prevNative = $null
    if (Test-Path 'variable:PSNativeCommandUseErrorActionPreference') {
        $prevNative = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $ErrorActionPreference = 'Continue'
    try { & docker @DockerArgs 2>$null } catch { } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) { $PSNativeCommandUseErrorActionPreference = $prevNative }
    }
}

# ── Isi berkas instalasi ─────────────────────────────────────────────────────
$ComposeYaml = @'
name: scada-ruanglab

# Stack produksi / on-premise. Image diambil dari ghcr.io — tidak perlu
# source code di server. Hanya file ini, .env, dan ./license/ yang dibutuhkan.
#
# Pemakaian:  install.sh / install.ps1   (pertama kali)
#             scada start                (selanjutnya)
#
# Image tersedia di:
#   ghcr.io/rumah-mulya-nusantara/scada-api
#   ghcr.io/rumah-mulya-nusantara/scada-web
#   ghcr.io/rumah-mulya-nusantara/scada-agent

services:
  db:
    image: timescale/timescaledb:2.17.2-pg16
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-scada}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD wajib diisi}
      POSTGRES_DB: ${POSTGRES_DB:-scada}
    volumes:
      - db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-scada} -d ${POSTGRES_DB:-scada}"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks: [backend]

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 12
    networks: [backend]

  api:
    image: ghcr.io/rumah-mulya-nusantara/scada-api:${IMAGE_TAG:-latest}
    restart: unless-stopped
    env_file: .env
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-scada}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB:-scada}
      REDIS_URL: redis://redis:6379/0
      LICENSE_FILE: /srv/license/license.key
    volumes:
      - ./license:/srv/license:ro
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health').status==200 else 1)\""]
      interval: 15s
      timeout: 5s
      retries: 6
      start_period: 20s
    networks: [backend, frontend]

  # Historian, alarm, retensi, watchdog agen. Image sama dengan api.
  worker:
    image: ghcr.io/rumah-mulya-nusantara/scada-api:${IMAGE_TAG:-latest}
    restart: unless-stopped
    env_file: .env
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-scada}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB:-scada}
      REDIS_URL: redis://redis:6379/0
      LICENSE_FILE: /srv/license/license.key
    volumes:
      - ./license:/srv/license:ro
    depends_on:
      api:
        condition: service_healthy
    command: ["python", "-m", "app.workers"]
    networks: [backend]

  web:
    image: ghcr.io/rumah-mulya-nusantara/scada-web:${IMAGE_TAG:-latest}
    restart: unless-stopped
    environment:
      API_ORIGIN: http://api:8000
      NEXT_PUBLIC_WS_URL: ${NEXT_PUBLIC_WS_URL:-}
    depends_on:
      - api
    networks: [frontend]

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "${HTTP_PORT:-80}:80"
      - "${HTTPS_PORT:-443}:443"
    environment:
      SITE_ADDRESS: ${SITE_ADDRESS:?SITE_ADDRESS wajib diisi}
      CADDY_TLS: ${CADDY_TLS:-}
    volumes:
      - ./infra/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - web
      - api
    networks: [frontend]

  # ─── Edge agent ────────────────────────────────────────────────────────────
  #
  # Ikut naik bersama `scada start`. Installer sudah membuat agen "Agen Lokal"
  # dan mengisi AGENT_ENROLLMENT_CODE di .env, jadi tidak ada langkah manual.
  # Setelah enrolment, kunci tersimpan di volume agent_state — kode tidak
  # diperlukan lagi dan bisa dikosongkan.
  # Menambah agen di komputer lain: UI → Agen → Buat agen baru.
  agent:
    image: ghcr.io/rumah-mulya-nusantara/scada-agent:${IMAGE_TAG:-latest}
    restart: on-failure
    env_file: .env
    environment:
      AGENT_API_URL: http://api:8000
      AGENT_ENROLLMENT_CODE: ${AGENT_ENROLLMENT_CODE:-}
      AGENT_STATE_DIR: /var/lib/scada-agent
      AGENT_LOG_LEVEL: ${AGENT_LOG_LEVEL:-INFO}
    volumes:
      - agent_state:/var/lib/scada-agent
    depends_on:
      api:
        condition: service_healthy
    networks: [backend]

# db dan redis hanya ada di jaringan `backend`; Caddy tidak bisa menyentuhnya.
networks:
  backend:
  frontend:

volumes:
  db_data:
  redis_data:
  caddy_data:
  caddy_config:
  agent_state:
'@

$Caddyfile = @'
{
	admin off
	persist_config off
}

{$SITE_ADDRESS} {
	{$CADDY_TLS}

	encode zstd gzip

	header {
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	# Browser hanya mengenal satu origin: yang ini. Cookie refresh httpOnly
	# karenanya tetap first-party tanpa perlu CORS.
	@api path /api/* /health /health/* /docs /openapi.json
	reverse_proxy @api api:8000

	reverse_proxy web:3000

	log {
		output stdout
		format console
	}
}
'@

$ResetPasswordPy = @'
"""Ganti kata sandi seorang pengguna langsung di database.

Dipakai lewat `scada reset-password`, yang mengalirkan berkas ini ke
`python -` di dalam kontainer api. Kredensial dibaca dari environment supaya
tidak pernah muncul di daftar proses.
"""

from __future__ import annotations

import asyncio
import os
import sys
from datetime import UTC, datetime

from sqlalchemy import select, update

from app.core.security import hash_password
from app.db.session import SessionLocal
from app.models.enums import UserStatus
from app.models.user import RefreshToken, User

MIN_PASSWORD_LENGTH = 8


async def reset() -> int:
    # authenticate() mencari dengan email.lower(); pencarian di sini harus sama.
    email = os.environ.get("RESET_EMAIL", "").strip().lower()
    password = os.environ.get("RESET_PASSWORD", "")

    if not email:
        print("! RESET_EMAIL kosong.", file=sys.stderr)
        return 2
    if len(password) < MIN_PASSWORD_LENGTH:
        print(f"! Kata sandi minimal {MIN_PASSWORD_LENGTH} karakter.", file=sys.stderr)
        return 2

    async with SessionLocal() as db:
        user = (await db.execute(select(User).where(User.email == email))).scalar_one_or_none()
        if user is None:
            print(f"! Pengguna {email} tidak ditemukan. Yang terdaftar:", file=sys.stderr)
            for row in (await db.execute(select(User.email).order_by(User.created_at))).scalars():
                print(f"    {row}", file=sys.stderr)
            return 1

        user.hashed_password = hash_password(password)

        # Akun undangan belum punya kata sandi, dan akun tangguhan ditolak saat
        # login; keduanya harus jadi aktif agar sandi baru ini berguna.
        if user.status is not UserStatus.ACTIVE:
            print(f"+ Status '{user.status.value}' diubah menjadi 'active'")
            user.status = UserStatus.ACTIVE

        # Sesi lama harus mati bersama kata sandi lama.
        revoked = await db.execute(
            update(RefreshToken)
            .where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=datetime.now(UTC))
        )
        await db.commit()

    print(f"+ Kata sandi {email} diperbarui")
    print(f"+ {revoked.rowcount or 0} sesi lama dicabut")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(reset()))
'@

$ScadaCli = @'
param([Parameter(Position = 0)][string]$Command = 'help',
      [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$TaskName = 'SCADA Auto Update'
$EnvPath  = Join-Path $PSScriptRoot '.env'
$StatePath = Join-Path $PSScriptRoot '.update-state'
$LogPath  = Join-Path $PSScriptRoot 'update.log'

function Compose { & docker compose -f 'docker-compose.prod.yml' @args }

# Lihat catatan di install.ps1: dengan $ErrorActionPreference = 'Stop',
# `docker ... 2>$null` yang gagal mematikan skrip ini. `scada doctor` justru
# dipakai saat stack rusak, jadi setiap probe di sini harus lewat fungsi ini.
function Invoke-DockerQuiet {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$DockerArgs)
    $prevEap = $ErrorActionPreference
    $prevNative = $null
    if (Test-Path 'variable:PSNativeCommandUseErrorActionPreference') {
        $prevNative = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $ErrorActionPreference = 'Continue'
    try { & docker @DockerArgs 2>$null } catch { } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) { $PSNativeCommandUseErrorActionPreference = $prevNative }
    }
}
function Compose-Quiet { Invoke-DockerQuiet compose -f 'docker-compose.prod.yml' @args }
function Save-Text ([string]$Path, [string]$Text) {
    $lf = $Text -replace "`r`n", "`n"
    if (-not $lf.EndsWith("`n")) { $lf += "`n" }
    [System.IO.File]::WriteAllText($Path, $lf, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-EnvValue ([string]$Key) {
    if (-not (Test-Path $EnvPath)) { return '' }
    $line = Get-Content $EnvPath | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^$Key=", '') }
    return ''
}
function Set-EnvValue ([string]$Key, [string]$Value) {
    $text = [System.IO.File]::ReadAllText($EnvPath) -replace "`r`n", "`n"
    # `$` punya arti khusus di bagian pengganti -replace ($1, $&), jadi sebuah
    # URL yang memuatnya akan tertulis rusak tanpa digandakan lebih dulu.
    $safe = "$Key=$Value".Replace('$', '$$')
    $pat  = '(?m)^' + [Regex]::Escape($Key) + '=.*$'
    if ($text -match $pat) { $text = $text -replace $pat, $safe }
    else { $text = $text.TrimEnd("`n") + "`n$Key=$Value`n" }
    Save-Text $EnvPath $text
}
function Get-Url { Get-EnvValue 'PUBLIC_URL' }

# Sidik jari image yang dipakai stack saat ini. Dibandingkan dengan yang terakhir
# berhasil dipasang, bukan dengan keadaan sebelum pull, supaya pembaruan yang
# gagal di tengah jalan dicoba lagi pada jadwal berikutnya.
function Get-ImageState {
    $images = @(Compose-Quiet config --images | Where-Object { $_ } | Sort-Object -Unique)
    $lines = foreach ($img in $images) {
        $id = Invoke-DockerQuiet image inspect --format '{{.Id}}' $img
        if (-not $id) { $id = 'belum' }
        "$img $id"
    }
    return ($lines -join "`n")
}
function Get-AppliedState {
    if (Test-Path $StatePath) { return ([System.IO.File]::ReadAllText($StatePath) -replace "`r`n", "`n").TrimEnd("`n") }
    return ''
}
function Wait-Healthy {
    $port = Get-EnvValue 'HTTP_PORT'
    if (-not $port) { $port = '80' }
    for ($i = 0; $i -lt 45; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { return $true }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}
function Backup-Database {
    New-Item -ItemType Directory -Force -Path 'backups' | Out-Null
    $f = "backups\scada-$(Get-Date -Format 'yyyyMMddTHHmmssZ').dump"
    & docker compose -f 'docker-compose.prod.yml' exec -T db pg_dump -U scada -Fc scada > $f
    Copy-Item $EnvPath "$f.env" -Force
    return $f
}
function Invoke-Update {
    $dump = ''
    Write-Host '· Menarik image terbaru...' -ForegroundColor Cyan
    Compose pull
    if (Compose ps -q db) {
        Write-Host '· Mencadangkan database dulu...' -ForegroundColor Cyan
        $dump = Backup-Database
        Write-Host "✔ Cadangan: $dump" -ForegroundColor Green
    }
    Compose up -d --wait db redis
    Write-Host '· Migrasi database...' -ForegroundColor Cyan
    Compose run --rm -T api alembic upgrade head
    Write-Host '· Menyalakan ulang layanan...' -ForegroundColor Cyan
    Compose up -d
    Save-Text $StatePath (Get-ImageState)
    if (Wait-Healthy) {
        Write-Host "✔ Pembaruan selesai — $(Get-Url)" -ForegroundColor Green
    } else {
        Write-Host '✘ Layanan belum sehat setelah pembaruan. Periksa: scada logs api' -ForegroundColor Red
        if ($dump) { Write-Host "  Pulihkan bila perlu: scada restore $dump" -ForegroundColor Red }
        exit 1
    }
}
function Get-UpdateTime {
    $t = Get-EnvValue 'AUTO_UPDATE_AT'
    if (-not $t) { $t = '02:30' }
    return $t
}
function Enable-AutoUpdate {
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        Write-Host '✘ Penjadwal tugas Windows tidak tersedia.' -ForegroundColor Red
        exit 1
    }
    $at = Get-UpdateTime
    Set-EnvValue 'AUTO_UPDATE' 'on'
    Set-EnvValue 'AUTO_UPDATE_AT' $at
    Save-Text $StatePath (Get-ImageState)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}\scada.ps1" _autoupdate' -f $PSScriptRoot)
    $trigger  = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($at, 'HH:mm', $null))
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RandomDelay (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description 'Pembaruan otomatis SCADA' -Force | Out-Null
    Write-Host "✔ Pembaruan otomatis aktif (Task Scheduler, sekitar pukul $at)" -ForegroundColor Green
}
function Disable-AutoUpdate {
    Set-EnvValue 'AUTO_UPDATE' 'off'
    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
    }
    Write-Host '✔ Pembaruan otomatis dimatikan' -ForegroundColor Green
}
function Show-AutoUpdate {
    $state = Get-EnvValue 'AUTO_UPDATE'
    if (-not $state) { $state = 'off' }
    Write-Host "  status   $state"
    Write-Host "  jadwal   sekitar pukul $(Get-UpdateTime) setiap hari"
    $task = $null
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    if ($task) {
        Write-Host '  mekanis  Task Scheduler'
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($info) { Write-Host "  berikut  $($info.NextRunTime)" }
    } else {
        Write-Host '  mekanis  belum terjadwal'
    }
    if (Test-Path $LogPath) {
        Write-Host "`n  catatan terakhir:"
        Get-Content $LogPath -Tail 8 | ForEach-Object { Write-Host "    $_" }
    }
}
function Invoke-AutoUpdateRun {
    Start-Transcript -Path $LogPath -Append | Out-Null
    try {
        Write-Host "=== $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) ==="
        if ((Get-EnvValue 'AUTO_UPDATE') -ne 'on') { Write-Host 'pembaruan otomatis nonaktif — dilewati'; return }
        Compose pull -q
        if ($LASTEXITCODE -ne 0) { Write-Host 'registry tidak terjangkau — dicoba lagi pada jadwal berikutnya'; return }
        if ((Get-ImageState) -eq (Get-AppliedState)) { Write-Host 'sudah versi terbaru'; return }
        Write-Host 'versi baru ditemukan — memasang'
        Invoke-Update
    } finally { Stop-Transcript | Out-Null }
}
function Test-UpdateAvailable {
    Write-Host '· Memeriksa versi terbaru...' -ForegroundColor Cyan
    Compose pull -q
    if ($LASTEXITCODE -ne 0) { Write-Host '✘ Registry tidak terjangkau.' -ForegroundColor Red; exit 1 }
    if ((Get-ImageState) -eq (Get-AppliedState)) {
        Write-Host '✔ Sudah versi terbaru.' -ForegroundColor Green
    } else {
        Write-Host '! Ada versi baru. Pasang dengan: scada update' -ForegroundColor Yellow
    }
}

switch ($Command) {
    'start'   { Compose up -d }
    'stop'    { Compose stop }
    'restart' { Compose up -d --force-recreate }
    'status'  { Compose ps }
    'ps'      { Compose ps }
    'logs'    { Compose logs -f --tail=100 @Rest }
    'url'     { Get-Url }
    'open'    { Start-Process (Get-Url) }
    'update'  {
        if ($Rest -and $Rest[0] -eq '--check') { Test-UpdateAvailable } else { Invoke-Update }
    }
    'autoupdate' {
        # switch ($null) tidak menjalankan cabang apa pun, default sekalipun.
        switch ([string]($Rest | Select-Object -First 1)) {
            'on'    { Enable-AutoUpdate }
            'off'   { Disable-AutoUpdate }
            default { Show-AutoUpdate }
        }
    }
    '_autoupdate' { Invoke-AutoUpdateRun }
    'doctor'  {
        Write-Host "Pemeriksaan SCADA — $PSScriptRoot`n" -ForegroundColor Cyan
        Write-Host 'Kontainer'; Compose-Quiet ps; Write-Host ''
        $port = Get-EnvValue 'HTTP_PORT'; if (-not $port) { $port = '80' }
        Write-Host 'Antarmuka'
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 3
            Write-Host "✔ http://127.0.0.1:$port/health menjawab ($($r.StatusCode))" -ForegroundColor Green
        } catch {
            Write-Host "✘ http://127.0.0.1:$port/health tidak menjawab" -ForegroundColor Red
        }
        Write-Host "`nAkun"
        $u = Get-EnvValue 'POSTGRES_USER'; $d = Get-EnvValue 'POSTGRES_DB'
        $orgs = (Compose-Quiet exec -T db psql -U $u -d $d -tAc 'select count(*) from organizations' | Out-String).Trim()
        $users = (Compose-Quiet exec -T db psql -U $u -d $d -tAc 'select count(*) from users' | Out-String).Trim()
        if (-not $orgs) {
            Write-Host '✘ Database belum bisa dibaca — migrasi mungkin belum jalan: scada logs db' -ForegroundColor Red
        } elseif ($orgs -eq '0' -or $users -eq '0') {
            Write-Host '✘ Belum ada organisasi/admin — itu sebabnya login ditolak.' -ForegroundColor Red
            Write-Host "    Buat sekarang:  scada create-admin email@anda.co.id 'KataSandiMin8'"
        } else {
            Write-Host "✔ $orgs organisasi, $users pengguna" -ForegroundColor Green
            Compose-Quiet exec -T db psql -U $u -d $d -tAc 'select email, role, status from users order by created_at limit 5' |
                ForEach-Object { Write-Host "    $_" }
        }
        Write-Host "`nGalat terakhir di api"
        Compose-Quiet logs --tail=30 api | Select-String -Pattern 'error|traceback|exception|critical' |
            Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" }
        Write-Host ''
    }
    'reset-password' {
        $email = $Rest | Select-Object -First 1
        $pass  = $Rest | Select-Object -Skip 1 -First 1
        if (-not $email -or -not $pass) {
            Write-Host "✘ Pemakaian: scada reset-password email@anda.co.id 'KataSandiMin8'" -ForegroundColor Red; exit 1
        }
        Get-Content -Raw (Join-Path $PSScriptRoot 'reset_password.py') |
            & docker compose -f 'docker-compose.prod.yml' run --rm -T `
                -e "RESET_EMAIL=$email" -e "RESET_PASSWORD=$pass" api python -
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Host "✔ Coba login sebagai $email" -ForegroundColor Green
    }
    'create-admin' {
        $email = $Rest | Select-Object -First 1
        $pass  = $Rest | Select-Object -Skip 1 -First 1
        if (-not $email -or -not $pass) {
            Write-Host "✘ Pemakaian: scada create-admin email@anda.co.id 'KataSandiMin8'" -ForegroundColor Red; exit 1
        }
        Compose run --rm -T -e "BOOTSTRAP_ADMIN_EMAIL=$email" -e "BOOTSTRAP_ADMIN_PASSWORD=$pass" `
            api python -m app.db.bootstrap
        New-Item -ItemType File -Path (Join-Path $PSScriptRoot '.bootstrap-done') -Force | Out-Null
        Write-Host "✔ Selesai. Coba login sebagai $email" -ForegroundColor Green
    }
    'enroll'  {
        $code = $Rest | Select-Object -First 1
        if (-not $code) { Write-Host '✘ Sertakan kode: scada enroll enr_xxxx' -ForegroundColor Red; exit 1 }
        Set-EnvValue 'AGENT_ENROLLMENT_CODE' $code
        Compose up -d --force-recreate agent
        Write-Host '✔ Agent didaftarkan. Pantau: scada logs agent' -ForegroundColor Green
    }
    'portal'  {
        # Mengganti alamat portal lisensi tanpa menjalankan installer lagi —
        # satu-satunya cara pada instalasi yang sudah berjalan.
        $arg = [string]($Rest | Select-Object -First 1)
        if (-not $arg) {
            $cur = Get-EnvValue 'LICENSE_PORTAL_URL'
            if ($cur) { Write-Host $cur }
            else { Write-Host 'tanpa portal — halaman Lisensi menyuruh kirim kode ke vendor' }
            break
        }
        if ($arg.Trim().ToLowerInvariant() -in @('off', 'none', 'no', '-', 'false')) { $arg = '' }
        else { $arg = $arg.Trim() }
        Set-EnvValue 'LICENSE_PORTAL_URL' $arg
        # api dan worker membaca .env lewat env_file, jadi keduanya perlu dibuat
        # ulang. Kalau stack memang sedang mati, jangan dinyalakan diam-diam.
        $running = @(Compose-Quiet ps -q api | Where-Object { $_ })
        if ($running.Count -gt 0) {
            Compose up -d --force-recreate api worker
            if ($arg) { Write-Host "✔ Portal lisensi: $arg" -ForegroundColor Green }
            else { Write-Host '✔ Portal lisensi dimatikan.' -ForegroundColor Green }
        } else {
            if ($arg) { Write-Host "✔ Portal lisensi: $arg (berlaku setelah: scada start)" -ForegroundColor Green }
            else { Write-Host '✔ Portal lisensi dimatikan. (berlaku setelah: scada start)' -ForegroundColor Green }
        }
    }
    'backup'  {
        $f = Backup-Database
        Write-Host "✔ Cadangan: $f (.env ikut disalin — wajib untuk membuka kredensial device)" -ForegroundColor Green
    }
    'restore' {
        $f = $Rest | Select-Object -First 1
        if (-not (Test-Path $f)) { Write-Host "✘ Berkas dump tidak ditemukan: $f" -ForegroundColor Red; exit 1 }
        Get-Content $f -Raw | & docker compose -f 'docker-compose.prod.yml' exec -T db pg_restore -U scada -d scada --clean --if-exists
        Write-Host "✔ Dipulihkan dari $f" -ForegroundColor Green
    }
    'uninstall' {
        $c = Read-Host "Hapus SELURUH data SCADA di $PSScriptRoot? Ketik `"hapus`" untuk lanjut"
        if ($c -ne 'hapus') { Write-Host 'Dibatalkan.'; exit 1 }
        Disable-AutoUpdate
        Compose down -v
        Write-Host "✔ Kontainer dan volume dihapus. Sisa berkas ada di $PSScriptRoot" -ForegroundColor Green
    }
    default {
        Write-Host "SCADA — $PSScriptRoot`n" -ForegroundColor Cyan
        Write-Host '  scada start | stop | restart | status'
        Write-Host '  scada logs [layanan]      ikuti log (api, web, worker, agent, db)'
        Write-Host '  scada open | url          buka antarmuka'
        Write-Host '  scada update              pasang versi terbaru sekarang'
        Write-Host '  scada update --check      lihat apakah ada versi baru'
        Write-Host '  scada autoupdate on|off   pembaruan otomatis harian'
        Write-Host '  scada autoupdate          status dan jadwalnya'
        Write-Host '  scada doctor              periksa kenapa tidak bisa dipakai'
        Write-Host '  scada create-admin <email> <sandi>   buat admin pertama'
        Write-Host '  scada reset-password <email> <sandi>  ganti kata sandi'
        Write-Host '  scada enroll enr_xxxx     daftarkan edge agent'
        Write-Host '  scada portal              lihat alamat portal lisensi'
        Write-Host '  scada portal <url>|off    ganti atau matikan tautan portal'
        Write-Host '  scada backup              cadangkan database + .env'
        Write-Host '  scada restore <berkas>    pulihkan dari cadangan'
        Write-Host '  scada uninstall           hapus kontainer dan volume'
        Write-Host ''
    }
}
'@

$ScadaCmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0scada.ps1`" %*`r`n"

# ── Alur utama ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '┌─ SCADA HMI Builder & Universal Gateway ─┐' -ForegroundColor Cyan
Write-Host ("│  installer v{0,-27} │" -f $ScadaVersion) -ForegroundColor Cyan
Write-Host '└─────────────────────────────────────────┘' -ForegroundColor Cyan

Initialize-Docker

if ($Uninstall) {
    if (-not (Test-Path (Join-Path $Dir 'docker-compose.prod.yml'))) { Die "Tidak ada instalasi di $Dir" }
    Set-Location $Dir
    if (-not (Confirm-Action "Hapus seluruh kontainer, volume, dan data SCADA di ${Dir}?")) { Die 'Dibatalkan.' }
    Invoke-Compose down -v
    Write-Ok "Instalasi dihentikan. Berkas konfigurasi masih ada di $Dir"
    exit 0
}

Write-Step '2/7  Direktori & jaringan'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Set-Location $Dir
foreach ($sub in @('license', 'backups', 'infra\caddy')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir $sub) | Out-Null
}
Write-Ok "Direktori instalasi: $Dir"

if (-not $HostAddress) { $HostAddress = Get-LocalIPAddress }

$HttpPort  = 80
$HttpsPort = 443
if ($Port -gt 0) {
    $HttpPort = $Port
} elseif (Test-PortBusy 80) {
    $HttpPort = 8080
    if (Test-PortBusy 8080) { $HttpPort = 8088 }
    Write-Warn2 "Port 80 sudah dipakai — memakai port $HttpPort"
}
if ($Https -and (Test-PortBusy 443)) {
    $HttpsPort = 8443
    Write-Warn2 "Port 443 sudah dipakai — memakai port $HttpsPort"
}

if ($Https) {
    $SiteAddress = "https://$HostAddress"
    $PublicUrl   = $SiteAddress
    if ($HttpsPort -ne 443) { $PublicUrl = "https://${HostAddress}:${HttpsPort}" }
    $CaddyTls      = 'tls internal'
    $CookieSecure  = 'true'
} else {
    # Caddy mendengar di port 80 dalam kontainer apa pun port host-nya, dan
    # blok `:80` cocok dengan Host apa pun — IP, hostname, maupun berport.
    $SiteAddress = ':80'
    $PublicUrl   = "http://$HostAddress"
    if ($HttpPort -ne 80) { $PublicUrl = "http://${HostAddress}:${HttpPort}" }
    $CaddyTls      = ''
    $CookieSecure  = 'false'
}
Write-Ok "Alamat server: $PublicUrl"

Write-Step '3/7  Akun admin'
$EnvPath = Join-Path $Dir '.env'
$MarkerPath = Join-Path $Dir '.bootstrap-done'
$Fresh = $false
if (Test-Path $EnvPath) {
    Write-Ok 'Konfigurasi lama terdeteksi — .env dipertahankan'
    $envText = [System.IO.File]::ReadAllText($EnvPath) -replace "`r`n", "`n"
    if ($envText -notmatch '(?m)^AUTO_UPDATE=') {
        $keep = $AutoUpdate
        if (-not $keep) { $keep = 'on' }
        $envText = $envText.TrimEnd("`n") +
            "`n`n# Pembaruan otomatis harian. Matikan di instalasi air-gapped: scada autoupdate off" +
            "`nAUTO_UPDATE=$keep`nAUTO_UPDATE_AT=$UpdateAt`n"
        Save-Text $EnvPath $envText
        $AutoUpdate = $keep
    } elseif ($AutoUpdate) {
        $envText = $envText -replace '(?m)^AUTO_UPDATE=.*$', "AUTO_UPDATE=$AutoUpdate"
        Save-Text $EnvPath $envText
    } else {
        $AutoUpdate = (($envText -split "`n" | Where-Object { $_ -match '^AUTO_UPDATE=' } |
                        Select-Object -First 1) -replace '^AUTO_UPDATE=', '')
    }

    # Alamat portal adalah bawaan produk, jadi instalasi lama ikut kena: baris
    # yang belum ada atau masih kosong diisi sekarang. Alamat yang sudah terisi
    # tidak disentuh kecuali override eksplisit — pelanggan boleh punya
    # portalnya sendiri, atau sengaja mematikannya lewat `scada portal off`,
    # dan itu harus bertahan lewat upgrade.
    $storedPortal = Get-EnvLine $EnvPath 'LICENSE_PORTAL_URL'
    if ($PortalExplicit) {
        Set-EnvLine $EnvPath 'LICENSE_PORTAL_URL' $LicensePortalUrl
    } elseif (-not $storedPortal) {
        Set-EnvLine $EnvPath 'LICENSE_PORTAL_URL' $LicensePortalUrl
        if ($LicensePortalUrl) { Write-Ok "Portal lisensi diisi: $LicensePortalUrl" }
    }
    $LicensePortalUrl = [string](Get-EnvLine $EnvPath 'LICENSE_PORTAL_URL')

    # Alamat di .env dibekukan dari pemasangan sebelumnya, sedangkan $PublicUrl
    # baru saja dideteksi ulang. Kalau DHCP mengubah alamat mesin, `scada url`
    # dan `scada open` akan mengarah ke alamat yang tidak menjawab.
    $storedUrl = Get-EnvLine $EnvPath 'PUBLIC_URL'
    if ($storedUrl -and $storedUrl -ne $PublicUrl) {
        # SITE_ADDRESS `:80` cocok dengan host apa pun, jadi alamat di .env hanya
        # dipakai untuk ditampilkan — aman ditulis ulang. Pemasangan https lain
        # perkara: nama host-nya ikut menentukan sertifikat.
        if ((Get-EnvLine $EnvPath 'SITE_ADDRESS') -eq ':80') {
            Set-EnvLine $EnvPath 'PUBLIC_URL' $PublicUrl
            Set-EnvLine $EnvPath 'CORS_ORIGINS' $PublicUrl
            Set-EnvLine $EnvPath 'NEXT_PUBLIC_WS_URL' ($PublicUrl -replace '^http', 'ws')
            Write-Warn2 "Alamat mesin berubah ($storedUrl -> $PublicUrl). .env diperbarui otomatis."
        } else {
            Write-Warn2 "Alamat di .env ($storedUrl) tidak sama dengan alamat mesin ini ($PublicUrl)."
            Write-Warn2 'Pemasangan https terikat nama host, jadi .env tidak diubah otomatis.'
            Write-Warn2 'Sunting SITE_ADDRESS/PUBLIC_URL/CORS_ORIGINS lalu jalankan: scada restart'
        }
    }
}

# `docker compose ps` menginterpolasi .env dan menolak jalan kalau variabel
# wajib seperti SITE_ADDRESS belum ada. Pada pemasangan baru .env memang belum
# ditulis di titik ini, jadi probe hanya boleh jalan kalau kedua berkasnya ada.
function Test-ApiContainerExists {
    if (-not (Test-Path (Join-Path $Dir 'docker-compose.prod.yml'))) { return $false }
    if (-not (Test-Path (Join-Path $Dir '.env')))                    { return $false }
    $ids = @(Invoke-DockerQuiet compose -f 'docker-compose.prod.yml' ps -aq api |
             Where-Object { $_ -and $_.Trim() })
    return ($ids.Count -gt 0)
}

# Adanya .env tidak membuktikan instalasi selesai: instalasi yang mati di tengah
# jalan meninggalkan .env tanpa akun admin. Yang membuktikannya adalah penanda
# ini, atau kontainer api dari instalasi sebelum penanda itu ada.
if (Test-Path $MarkerPath) {
    $Fresh = $false
} elseif (Test-ApiContainerExists) {
    New-Item -ItemType File -Path $MarkerPath -Force | Out-Null
    $Fresh = $false
} else {
    $Fresh = $true
}

if (-not $Fresh) {
    Write-Ok 'Akun admin sudah ada — tidak dibuat ulang'
} elseif ($Yes) {
    if (-not $AdminEmail) { Die 'SCADA_ADMIN_EMAIL wajib diisi pada mode non-interaktif' }
    if ($AdminPassword.Length -lt 8) { Die 'SCADA_ADMIN_PASSWORD minimal 8 karakter' }
} else {
    while (-not $AdminEmail) { $AdminEmail = Read-Host 'Email admin' }
    while ($AdminPassword.Length -lt 8) {
        $secure = Read-Host 'Kata sandi admin (min. 8 karakter)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if ($AdminPassword.Length -lt 8) { Write-Warn2 'Terlalu pendek, coba lagi.' }
    }
}

if (-not (Test-Path $EnvPath)) {

    if (-not $AutoUpdate) {
        if ($Yes) { $AutoUpdate = 'on' }
        elseif (Confirm-Action "Pasang pembaruan otomatis setiap malam pukul ${UpdateAt}?") { $AutoUpdate = 'on' }
        else { $AutoUpdate = 'off' }
    }

    $wsUrl = $PublicUrl -replace '^http', 'ws'
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $envText = @"
# Dibuat oleh install.ps1 v$ScadaVersion — $stamp
# Nama project Docker Compose. Berdiri sendiri supaya pemasangan ini tidak pernah
# berbagi container atau volume dengan stack lain di mesin yang sama — misalnya
# checkout pengembangan, yang compose-nya memakai nama bawaan yang sama.
# Instalasi lama tidak punya baris ini dan tetap memakai nama bawaan itu, jadi
# volumenya tidak berpindah.
COMPOSE_PROJECT_NAME=scada-onprem

DEPLOYMENT_MODE=onprem
ENVIRONMENT=production
LOG_LEVEL=INFO

SITE_ADDRESS=$SiteAddress
PUBLIC_URL=$PublicUrl
CORS_ORIGINS=$PublicUrl
NEXT_PUBLIC_WS_URL=$wsUrl
HTTP_PORT=$HttpPort
HTTPS_PORT=$HttpsPort
CADDY_TLS=$CaddyTls

POSTGRES_USER=scada
POSTGRES_PASSWORD=$(New-HexKey 24)
POSTGRES_DB=scada

SECRET_KEY=$(New-HexKey 32)
ENCRYPTION_KEY=$(New-UrlSafeKey 32)
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=30
COOKIE_SECURE=$CookieSecure
COOKIE_DOMAIN=

# Diisi otomatis oleh installer (agen "Agen Lokal"), atau: scada enroll enr_xxxx
AGENT_ENROLLMENT_CODE=
AGENT_LOG_LEVEL=INFO

LICENSE_FILE=/srv/license/license.key
LICENSE_PORTAL_URL=$LicensePortalUrl
IMAGE_TAG=$ImageTag

# Pembaruan otomatis harian. Matikan di instalasi air-gapped: scada autoupdate off
AUTO_UPDATE=$AutoUpdate
AUTO_UPDATE_AT=$UpdateAt
"@
    Save-Text $EnvPath $envText
    Write-Ok 'Konfigurasi dan rahasia dibuat'
}

Save-Text (Join-Path $Dir 'docker-compose.prod.yml')   $ComposeYaml
Save-Text (Join-Path $Dir 'infra\caddy\Caddyfile')     $Caddyfile

Write-Step "4/7  Mengunduh image ($ImageTag)"
Invoke-Compose pull
Write-Ok 'Image siap'

Write-Step '5/7  Database'
Invoke-Compose up -d --wait db redis
Invoke-Compose run --rm -T api alembic upgrade head
Invoke-Compose run --rm -T api python -m app.db.seed
Write-Ok 'Skema dan data awal siap'

if ($Fresh) {
    Invoke-Compose run --rm -T `
        -e "BOOTSTRAP_ORG_NAME=$OrgName" `
        -e "BOOTSTRAP_ADMIN_NAME=$AdminName" `
        -e "BOOTSTRAP_ADMIN_EMAIL=$AdminEmail" `
        -e "BOOTSTRAP_ADMIN_PASSWORD=$AdminPassword" `
        api python -m app.db.bootstrap
    New-Item -ItemType File -Path $MarkerPath -Force | Out-Null
    Write-Ok "Akun admin dibuat: $AdminEmail"
}

# Tanpa kode enrolment kontainer agen keluar dengan galat dan direstart
# terus-menerus. Agen di satu server tidak perlu ritual salin-kode dari UI,
# jadi installer yang menyiapkannya.
$AgentProvisioned = $false
$agentOut = Invoke-DockerQuiet compose -f 'docker-compose.prod.yml' run --rm -T api python -m app.db.provision_agent
$agentExit = $LASTEXITCODE
if ($agentExit -eq 0) {
    $AgentProvisioned = $true
    $m = [regex]::Match(($agentOut -join "`n"), 'enr_[A-Za-z0-9_-]+')
    if ($m.Success) {
        Set-EnvLine $EnvPath 'AGENT_ENROLLMENT_CODE' $m.Value
        Write-Ok 'Agen lokal disiapkan'
    } else {
        Write-Ok 'Agen lokal sudah terdaftar'
    }
} else {
    Write-Warn2 'Penyiapan agen lokal gagal — daftarkan lewat UI → Agen, lalu: scada enroll enr_xxxx'
}

Write-Step '6/7  Menyalakan layanan'
Invoke-Compose up -d
Write-Host '· Menunggu antarmuka siap' -ForegroundColor Cyan -NoNewline
$Healthy = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$HttpPort/health" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $Healthy = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
    Write-Host '.' -NoNewline
}
Write-Host ''
# Enrolment yang gagal hanya terlihat sebagai kontainer yang restart terus,
# jadi hasilnya dipastikan di sini selagi installer masih di layar.
if ($AgentProvisioned) {
    $agentReady = $false
    for ($i = 0; $i -lt 20; $i++) {
        $agentLogs = (Invoke-DockerQuiet compose -f 'docker-compose.prod.yml' logs agent) -join "`n"
        if ($agentLogs -match 'Enrolment berhasil|Kunci agen dimuat') { $agentReady = $true; break }
        Start-Sleep -Seconds 3
    }
    if ($agentReady) {
        Write-Ok 'Agen lokal terhubung'
    } else {
        $AgentProvisioned = $false
        Write-Warn2 'Agen lokal belum terhubung — periksa: scada logs agent'
    }
}

if ($Healthy) {
    Write-Ok 'Semua layanan berjalan'
} else {
    Write-Err2 'Layanan belum menjawab setelah 2 menit.'
    Invoke-Compose ps
    Write-Err2 'Lihat sebabnya: scada logs api'
}

Write-Step '7/7  Perintah scada'
Save-Text (Join-Path $Dir 'scada.ps1') $ScadaCli
Save-Text (Join-Path $Dir 'reset_password.py') $ResetPasswordPy
[System.IO.File]::WriteAllText((Join-Path $Dir 'scada.cmd'), $ScadaCmd, (New-Object System.Text.UTF8Encoding($false)))

if ($AutoUpdate -eq 'on') {
    try {
        & (Join-Path $Dir 'scada.ps1') autoupdate on
    } catch {
        $AutoUpdate = 'off'
        Write-Warn2 'Penjadwalan gagal — jalankan sendiri nanti: scada autoupdate on'
    }
} else {
    Write-Ok 'Pembaruan otomatis mati — pasang manual dengan: scada update'
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$Dir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$Dir", 'User')
    $env:Path = "$env:Path;$Dir"
    Write-Ok "Perintah 'scada' ditambahkan ke PATH (berlaku penuh di terminal baru)"
} else {
    Write-Ok "Perintah 'scada' siap"
}

Write-Host ''
if ($Healthy) {
    Write-Host '  ✔  SCADA siap dipakai' -ForegroundColor Green
} else {
    Write-Host '  !  SCADA terpasang tetapi belum menjawab — jalankan: scada doctor' -ForegroundColor Yellow
}
Write-Host ''
Write-Host "     Buka       $PublicUrl"
if ($AdminEmail) { Write-Host "     Login      $AdminEmail" }
Write-Host "     Kelola     scada  (start, stop, logs, update, backup)"
if ($AutoUpdate -eq 'on') {
    Write-Host "     Pembaruan  otomatis tiap malam pukul $UpdateAt  (scada autoupdate off untuk mematikan)"
}
Write-Host ''
# Tanpa baris ini pemasang tidak pernah tahu ada hitungan mundur yang sudah
# berjalan; yang ia temukan nanti hanya penolakan 402 saat menambah device.
Write-Host '     Lisensi   Mode DEMO, hitungannya sudah mulai: 2 device, 100 tag, 2 user.'
if ($LicensePortalUrl) {
    Write-Host '               Aktifkan: menu Lisensi → Salin kode → ajukan di' -ForegroundColor DarkGray
    Write-Host "               $LicensePortalUrl"
} else {
    Write-Host '               Aktifkan: menu Lisensi → Salin kode → kirim ke vendor.' -ForegroundColor DarkGray
    Write-Host '               Server ini tidak menghubungi siapa pun.' -ForegroundColor DarkGray
}
Write-Host ''
if ($AgentProvisioned) {
    Write-Host '     Edge agent "Agen Lokal" sudah berjalan — tinggal tambahkan device di UI.' -ForegroundColor DarkGray
    Write-Host '     Agen di komputer lain: UI → Agen → salin kode → scada enroll enr_xxxx' -ForegroundColor DarkGray
} else {
    Write-Host '     Langkah berikutnya: buat agen di UI → Agen → salin kode → jalankan' -ForegroundColor DarkGray
    Write-Host '     scada enroll enr_xxxx' -ForegroundColor DarkGray
}
Write-Host ''
