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
    [string]$AutoUpdate    = $env:SCADA_AUTO_UPDATE,
    [string]$UpdateAt      = $env:SCADA_UPDATE_AT,
    [switch]$Https,
    [switch]$NoDockerInstall,
    [switch]$Yes,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ScadaVersion = '2.0.0'

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
  # Ikut naik bersama `scada start`. Pertama kali jalankan:
  #   1. Buka UI → Agen → Buat agen baru → salin enrollment code
  #   2. Jalankan: scada enroll enr_xxxx
  # Setelah enrolment, kunci tersimpan di volume agent_state — kode tidak
  # diperlukan lagi dan bisa dikosongkan.
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
    if ($text -match "(?m)^$Key=.*$") { $text = $text -replace "(?m)^$Key=.*$", "$Key=$Value" }
    else { $text = $text.TrimEnd("`n") + "`n$Key=$Value`n" }
    Save-Text $EnvPath $text
}
function Get-Url { Get-EnvValue 'PUBLIC_URL' }

# Sidik jari image yang dipakai stack saat ini. Dibandingkan dengan yang terakhir
# berhasil dipasang, bukan dengan keadaan sebelum pull, supaya pembaruan yang
# gagal di tengah jalan dicoba lagi pada jadwal berikutnya.
function Get-ImageState {
    $images = @(Compose config --images 2>$null | Sort-Object -Unique)
    $lines = foreach ($img in $images) {
        $id = & docker image inspect --format '{{.Id}}' $img 2>$null
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
    'enroll'  {
        $code = $Rest | Select-Object -First 1
        if (-not $code) { Write-Host '✘ Sertakan kode: scada enroll enr_xxxx' -ForegroundColor Red; exit 1 }
        Set-EnvValue 'AGENT_ENROLLMENT_CODE' $code
        Compose up -d --force-recreate agent
        Write-Host '✔ Agent didaftarkan. Pantau: scada logs agent' -ForegroundColor Green
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
        Write-Host '  scada enroll enr_xxxx     daftarkan edge agent'
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
$Fresh = $false
if (Test-Path $EnvPath) {
    Write-Ok 'Instalasi lama terdeteksi — .env dipertahankan, admin tidak dibuat ulang'
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
} else {
    $Fresh = $true
    if ($Yes) {
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

    if (-not $AutoUpdate) {
        if ($Yes) { $AutoUpdate = 'on' }
        elseif (Confirm-Action "Pasang pembaruan otomatis setiap malam pukul ${UpdateAt}?") { $AutoUpdate = 'on' }
        else { $AutoUpdate = 'off' }
    }

    $wsUrl = $PublicUrl -replace '^http', 'ws'
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $envText = @"
# Dibuat oleh install.ps1 v$ScadaVersion — $stamp
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

# Diisi otomatis oleh: scada enroll enr_xxxx
AGENT_ENROLLMENT_CODE=
AGENT_LOG_LEVEL=INFO

LICENSE_FILE=/srv/license/license.key
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
    Write-Ok "Akun admin dibuat: $AdminEmail"
}

Write-Step '6/7  Menyalakan layanan'
Invoke-Compose up -d
Write-Host '· Menunggu antarmuka siap' -ForegroundColor Cyan -NoNewline
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$HttpPort/health" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { break }
    } catch { }
    Start-Sleep -Seconds 2
    Write-Host '.' -NoNewline
}
Write-Host ''
Write-Ok 'Semua layanan berjalan'

Write-Step '7/7  Perintah scada'
Save-Text (Join-Path $Dir 'scada.ps1') $ScadaCli
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
Write-Host '  ✔  SCADA siap dipakai' -ForegroundColor Green
Write-Host ''
Write-Host "     Buka       $PublicUrl"
if ($AdminEmail) { Write-Host "     Login      $AdminEmail" }
Write-Host "     Kelola     scada  (start, stop, logs, update, backup)"
if ($AutoUpdate -eq 'on') {
    Write-Host "     Pembaruan  otomatis tiap malam pukul $UpdateAt  (scada autoupdate off untuk mematikan)"
}
Write-Host ''
Write-Host '     Langkah berikutnya: buat agen di UI → Agen → salin kode → jalankan' -ForegroundColor DarkGray
Write-Host '     scada enroll enr_xxxx' -ForegroundColor DarkGray
Write-Host ''
