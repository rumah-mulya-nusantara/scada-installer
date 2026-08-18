#!/usr/bin/env bash
#
# Pemasang SCADA HMI Builder & Universal Gateway — satu berkas, satu perintah.
#
#   curl -fsSL https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.sh | bash
#
# Non-interaktif:
#
#   curl -fsSL .../install.sh | bash -s -- --yes --admin-email a@b.c --admin-password 'Rahasia123'
#
# Opsi:
#   --dir <path>            direktori instalasi
#   --host <ip|domain>      alamat server (default: deteksi otomatis)
#   --port <n>              port HTTP (default: 80, mundur ke 8080 bila terpakai)
#   --org <nama>            nama organisasi
#   --admin-name <nama>     nama admin
#   --admin-email <email>   email admin
#   --admin-password <pw>   kata sandi admin (min. 8 karakter)
#   --tag <versi>           tag image (default: latest)
#   --https                 aktifkan TLS internal Caddy
#   --no-docker-install     jangan pasang Docker otomatis
#   --yes, -y               jangan bertanya apa pun
#   --uninstall             hapus instalasi
#
set -euo pipefail

SCADA_VERSION="2.0.0"

RED=''; GRN=''; YLW=''; CYN=''; DIM=''; BLD=''; RST=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'
    DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'
fi

ok()   { printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s·%s %s\n' "$CYN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YLW" "$RST" "$*"; }
err()  { printf '%s✘%s %s\n' "$RED" "$RST" "$*" >&2; }
step() { printf '\n%s%s%s\n' "$BLD" "$*" "$RST"; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }

# ── Masukan pengguna ─────────────────────────────────────────────────────────
# Skrip ini lazim dijalankan lewat `curl | bash`; stdin sudah dipakai pipa,
# jadi setiap pertanyaan dibaca langsung dari terminal.
TTY=""

init_tty() {
    if [ -r /dev/tty ] && { : > /dev/tty; } 2>/dev/null; then
        TTY=/dev/tty
    elif [ -t 0 ]; then
        TTY=/dev/stdin
    fi
}

ask() {
    local prompt="$1" default="${2:-}" reply=""
    [ -n "$TTY" ] || die "Tidak ada terminal untuk bertanya. Jalankan dengan --yes dan lengkapi opsinya."
    if [ -n "$default" ]; then
        printf '%s %s[%s]%s ' "$prompt" "$DIM" "$default" "$RST" > "$TTY"
    else
        printf '%s ' "$prompt" > "$TTY"
    fi
    IFS= read -r reply < "$TTY" || true
    printf '%s' "${reply:-$default}"
}

ask_secret() {
    local prompt="$1" reply=""
    [ -n "$TTY" ] || die "Tidak ada terminal untuk bertanya. Jalankan dengan --yes dan lengkapi opsinya."
    printf '%s ' "$prompt" > "$TTY"
    stty -echo < "$TTY" 2>/dev/null || true
    IFS= read -r reply < "$TTY" || true
    stty echo < "$TTY" 2>/dev/null || true
    printf '\n' > "$TTY"
    printf '%s' "$reply"
}

confirm() {
    local prompt="$1" reply
    [ "$ASSUME_YES" -eq 1 ] && return 0
    reply="$(ask "$prompt ${DIM}(y/N)${RST}")"
    case "$reply" in [yY]*|[yY][aA]*) return 0 ;; *) return 1 ;; esac
}

# ── Acak ─────────────────────────────────────────────────────────────────────
rand_hex() {
    local n="$1"
    if have openssl; then
        openssl rand -hex "$n"
    elif have od; then
        od -An -N"$n" -tx1 /dev/urandom | tr -d ' \n'
    else
        die "Butuh openssl atau od untuk membangkitkan rahasia."
    fi
}

rand_urlsafe_b64() {
    local n="$1"
    if have openssl; then
        openssl rand "$n" | base64 | tr -d '\n' | tr '+/' '-_'
    else
        head -c "$n" /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_'
    fi
}

# ── Lingkungan ───────────────────────────────────────────────────────────────
OS=""; SUDO=""

detect_os() {
    case "$(uname -s)" in
        Linux*)   OS="linux" ;;
        Darwin*)  OS="macos" ;;
        MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
        *)        OS="unknown" ;;
    esac
    if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO="sudo"; fi
}

default_dir() {
    # Docker Desktop hanya membagikan $HOME secara bawaan; /opt tidak terlihat
    # oleh kontainer di macOS maupun Windows.
    if [ "$OS" = "linux" ] && { [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; }; then
        printf '/opt/scada'
    else
        printf '%s/scada' "$HOME"
    fi
}

detect_ip() {
    local ip=""
    case "$OS" in
        linux)
            have ip && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
            [ -z "$ip" ] && have hostname && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            ;;
        macos)
            ip="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
            [ -n "$ip" ] && ip="$(ipconfig getifaddr "$ip" 2>/dev/null || true)"
            [ -z "$ip" ] && ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
            ;;
    esac
    printf '%s' "${ip:-localhost}"
}

env_value() {
    [ -f .env ] || return 0
    sed -n "s/^$1=//p" .env | head -1
}

port_busy() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") > /dev/null 2>&1
}

# ── Docker ───────────────────────────────────────────────────────────────────
DOCKER=""; COMPOSE=""

wait_for_daemon() {
    local tries="${1:-60}" i=0
    while [ "$i" -lt "$tries" ]; do
        if $DOCKER info > /dev/null 2>&1; then return 0; fi
        sleep 2; i=$((i + 1))
        printf '.'
    done
    return 1
}

install_docker_linux() {
    have curl || die "curl tidak tersedia — tidak bisa memasang Docker otomatis."
    info "Memasang Docker Engine (get.docker.com)..."
    curl -fsSL https://get.docker.com | $SUDO sh
    if have systemctl; then
        $SUDO systemctl enable --now docker > /dev/null 2>&1 || true
    elif have service; then
        $SUDO service docker start > /dev/null 2>&1 || true
    fi
    if [ "$(id -u)" -ne 0 ] && have usermod; then
        $SUDO usermod -aG docker "$(id -un)" > /dev/null 2>&1 || true
        warn "Pengguna $(id -un) ditambahkan ke grup docker — login ulang agar berlaku tanpa sudo."
    fi
}

install_docker_macos() {
    if have brew; then
        info "Memasang Docker Desktop (Homebrew)..."
        brew install --cask docker
    else
        die "Homebrew tidak ada. Pasang Docker Desktop dulu: https://www.docker.com/products/docker-desktop/"
    fi
}

start_docker_desktop() {
    if [ -d "/Applications/Docker.app" ]; then
        info "Menyalakan Docker Desktop..."
        open -a Docker || true
        printf '%s· Menunggu Docker siap%s' "$CYN" "$RST"
        wait_for_daemon 90 && printf '\n' && return 0
        printf '\n'
    fi
    return 1
}

ensure_docker() {
    step "1/7  Docker"
    DOCKER="docker"

    if ! have docker; then
        if [ "$AUTO_DOCKER" -eq 0 ]; then
            die "Docker belum terpasang. Pasang dulu: https://docs.docker.com/engine/install/"
        fi
        case "$OS" in
            linux) confirm "Docker belum terpasang. Pasang sekarang?" || die "Dibatalkan." ; install_docker_linux ;;
            macos) confirm "Docker Desktop belum terpasang. Pasang lewat Homebrew?" || die "Dibatalkan." ; install_docker_macos ;;
            *)     die "Docker belum terpasang. Pasang dulu: https://docs.docker.com/get-docker/" ;;
        esac
        have docker || die "Docker terpasang tetapi belum ada di PATH. Buka terminal baru lalu ulangi."
    fi

    if ! $DOCKER info > /dev/null 2>&1; then
        if [ -n "$SUDO" ] && $SUDO docker info > /dev/null 2>&1; then
            DOCKER="$SUDO docker"
        elif [ "$OS" = "macos" ]; then
            start_docker_desktop || die "Docker Desktop tidak merespons. Jalankan aplikasinya lalu ulangi."
        elif have systemctl; then
            info "Menyalakan layanan Docker..."
            $SUDO systemctl start docker > /dev/null 2>&1 || true
            $DOCKER info > /dev/null 2>&1 || DOCKER="$SUDO docker"
            $DOCKER info > /dev/null 2>&1 || die "Docker daemon tidak berjalan."
        else
            die "Docker daemon tidak berjalan."
        fi
    fi

    if $DOCKER compose version > /dev/null 2>&1; then
        COMPOSE="$DOCKER compose"
    elif have docker-compose; then
        COMPOSE="docker-compose"
    else
        die "Plugin 'docker compose' v2 tidak tersedia. Perbarui Docker."
    fi

    ok "Docker $($DOCKER version --format '{{.Server.Version}}' 2>/dev/null || echo '?') siap"
}

dc() { $COMPOSE -f docker-compose.prod.yml "$@"; }

# ── Berkas instalasi ─────────────────────────────────────────────────────────
write_compose() {
    cat > docker-compose.prod.yml <<'YAML'
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
YAML
}

write_caddyfile() {
    mkdir -p infra/caddy
    cat > infra/caddy/Caddyfile <<'CADDY'
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
CADDY
}

write_env() {
    local secret enc pgpw cookie_secure caddy_tls ws_url
    secret="$(rand_hex 32)"
    enc="$(rand_urlsafe_b64 32)"
    pgpw="$(rand_hex 24)"
    ws_url="$(printf '%s' "$PUBLIC_URL" | sed 's|^http|ws|')"
    if [ "$SCHEME" = "https" ]; then
        cookie_secure="true"; caddy_tls="tls internal"
    else
        cookie_secure="false"; caddy_tls=""
    fi

    umask 077
    cat > .env <<ENV
# Dibuat oleh install.sh v$SCADA_VERSION — $(date -u +%Y-%m-%dT%H:%M:%SZ)
DEPLOYMENT_MODE=onprem
ENVIRONMENT=production
LOG_LEVEL=INFO

SITE_ADDRESS=$SITE_ADDRESS
PUBLIC_URL=$PUBLIC_URL
CORS_ORIGINS=$PUBLIC_URL
NEXT_PUBLIC_WS_URL=$ws_url
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
CADDY_TLS=$caddy_tls

POSTGRES_USER=scada
POSTGRES_PASSWORD=$pgpw
POSTGRES_DB=scada

SECRET_KEY=$secret
ENCRYPTION_KEY=$enc
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=30
COOKIE_SECURE=$cookie_secure
COOKIE_DOMAIN=

# Diisi otomatis oleh: scada enroll enr_xxxx
AGENT_ENROLLMENT_CODE=
AGENT_LOG_LEVEL=INFO

LICENSE_FILE=/srv/license/license.key
IMAGE_TAG=$IMAGE_TAG
ENV
    umask 022
}

write_cli() {
    printf '#!/usr/bin/env bash\nSCADA_DIR="%s"\nSCADA_DOCKER="%s"\n' "$DIR" "$COMPOSE" > scada
    cat >> scada <<'CLI'
set -euo pipefail
cd "$SCADA_DIR"

GRN=$'\033[32m'; RED=$'\033[31m'; CYN=$'\033[36m'; DIM=$'\033[2m'; RST=$'\033[0m'
dc() { $SCADA_DOCKER -f docker-compose.prod.yml "$@"; }
url() { grep -E '^PUBLIC_URL=' .env 2>/dev/null | cut -d= -f2- ; }

case "${1:-help}" in
    start)    dc up -d ;;
    stop)     dc stop ;;
    restart)  dc up -d --force-recreate ;;
    status|ps) dc ps ;;
    logs)     shift; dc logs -f --tail=100 "$@" ;;
    url)      url ;;
    open)
        u="$(url)"
        command -v open        > /dev/null 2>&1 && open "$u"        && exit 0
        command -v xdg-open    > /dev/null 2>&1 && xdg-open "$u"    && exit 0
        echo "$u" ;;
    update)
        dc pull
        dc up -d --wait db redis
        dc run --rm api alembic upgrade head
        dc up -d --force-recreate
        printf '%s✔%s Diperbarui ke image terbaru\n' "$GRN" "$RST" ;;
    enroll)
        code="${2:-}"
        [ -n "$code" ] || { printf '%s✘%s Sertakan kode: scada enroll enr_xxxx\n' "$RED" "$RST"; exit 1; }
        if grep -q '^AGENT_ENROLLMENT_CODE=' .env; then
            sed -i.bak "s|^AGENT_ENROLLMENT_CODE=.*|AGENT_ENROLLMENT_CODE=$code|" .env && rm -f .env.bak
        else
            printf 'AGENT_ENROLLMENT_CODE=%s\n' "$code" >> .env
        fi
        dc up -d --force-recreate agent
        printf '%s✔%s Agent didaftarkan. Pantau: scada logs agent\n' "$GRN" "$RST" ;;
    backup)
        mkdir -p backups
        f="backups/scada-$(date -u +%Y%m%dT%H%M%SZ).dump"
        dc exec -T db pg_dump -U scada -Fc scada > "$f"
        cp .env "$f.env"
        printf '%s✔%s Cadangan: %s %s(.env ikut disalin — wajib untuk membuka kredensial device)%s\n' \
            "$GRN" "$RST" "$f" "$DIM" "$RST" ;;
    restore)
        f="${2:-}"
        [ -f "$f" ] || { printf '%s✘%s Berkas dump tidak ditemukan: %s\n' "$RED" "$RST" "$f"; exit 1; }
        dc exec -T db pg_restore -U scada -d scada --clean --if-exists < "$f"
        printf '%s✔%s Dipulihkan dari %s\n' "$GRN" "$RST" "$f" ;;
    uninstall)
        printf 'Hapus SELURUH data SCADA di %s? Ketik "hapus" untuk lanjut: ' "$SCADA_DIR"
        read -r c
        [ "$c" = "hapus" ] || { echo "Dibatalkan."; exit 1; }
        dc down -v
        printf '%s✔%s Kontainer dan volume dihapus. Sisa berkas ada di %s\n' "$GRN" "$RST" "$SCADA_DIR" ;;
    *)
        printf '%sSCADA%s — %s\n\n' "$CYN" "$RST" "$SCADA_DIR"
        printf '  scada start | stop | restart | status\n'
        printf '  scada logs [layanan]     ikuti log (api, web, worker, agent, db)\n'
        printf '  scada open | url         buka antarmuka\n'
        printf '  scada update             tarik image terbaru + migrasi\n'
        printf '  scada enroll enr_xxxx    daftarkan edge agent\n'
        printf '  scada backup             cadangkan database + .env\n'
        printf '  scada restore <berkas>   pulihkan dari cadangan\n'
        printf '  scada uninstall          hapus kontainer dan volume\n\n' ;;
esac
CLI
    chmod +x scada

    if [ -w /usr/local/bin ] && ln -sf "$DIR/scada" /usr/local/bin/scada 2>/dev/null; then
        CLI_PATH="/usr/local/bin/scada"
    elif [ -n "$SUDO" ] && $SUDO ln -sf "$DIR/scada" /usr/local/bin/scada 2>/dev/null; then
        CLI_PATH="/usr/local/bin/scada"
    elif mkdir -p "$HOME/.local/bin" && ln -sf "$DIR/scada" "$HOME/.local/bin/scada" 2>/dev/null; then
        CLI_PATH="$HOME/.local/bin/scada"
    else
        CLI_PATH="$DIR/scada"
    fi
}

show_help() {
    cat <<'HELP'
Pemasang SCADA HMI Builder & Universal Gateway.

  curl -fsSL https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.sh | bash

Opsi:
  --dir <path>            direktori instalasi
  --host <ip|domain>      alamat server (default: deteksi otomatis)
  --port <n>              port HTTP (default: 80, mundur ke 8080 bila terpakai)
  --org <nama>            nama organisasi
  --admin-name <nama>     nama admin
  --admin-email <email>   email admin
  --admin-password <pw>   kata sandi admin (min. 8 karakter)
  --tag <versi>           tag image (default: latest)
  --https                 aktifkan TLS internal Caddy
  --no-docker-install     jangan pasang Docker otomatis
  --yes, -y               jangan bertanya apa pun
  --uninstall             hapus instalasi

Setiap opsi juga bisa lewat environment: SCADA_DIR, SCADA_HOST, SCADA_PORT,
SCADA_ORG, SCADA_ADMIN_NAME, SCADA_ADMIN_EMAIL, SCADA_ADMIN_PASSWORD, SCADA_TAG.
HELP
}

# ── Uninstall ────────────────────────────────────────────────────────────────
do_uninstall() {
    [ -f "$DIR/docker-compose.prod.yml" ] || die "Tidak ada instalasi di $DIR"
    cd "$DIR"
    confirm "Hapus seluruh kontainer, volume, dan data SCADA di $DIR?" || die "Dibatalkan."
    dc down -v || true
    $SUDO rm -f /usr/local/bin/scada "$HOME/.local/bin/scada" 2>/dev/null || true
    ok "Instalasi dihentikan. Berkas konfigurasi masih ada di $DIR (hapus manual bila perlu)."
    exit 0
}

# ── Alur utama ───────────────────────────────────────────────────────────────
DIR="${SCADA_DIR:-}"
HOST="${SCADA_HOST:-}"
HTTP_PORT="${SCADA_PORT:-}"
HTTPS_PORT=443
SCHEME="http"
ORG_NAME="${SCADA_ORG:-SCADA}"
ADMIN_NAME="${SCADA_ADMIN_NAME:-Administrator}"
ADMIN_EMAIL="${SCADA_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${SCADA_ADMIN_PASSWORD:-}"
IMAGE_TAG="${SCADA_TAG:-latest}"
ASSUME_YES=0
AUTO_DOCKER=1
UNINSTALL=0
CLI_PATH=""
SITE_ADDRESS=""
PUBLIC_URL=""
FRESH=0
REUSED_ENV=0

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)            DIR="$2";            shift 2 ;;
            --host)           HOST="$2";           shift 2 ;;
            --port)           HTTP_PORT="$2";      shift 2 ;;
            --org)            ORG_NAME="$2";       shift 2 ;;
            --admin-name)     ADMIN_NAME="$2";     shift 2 ;;
            --admin-email)    ADMIN_EMAIL="$2";    shift 2 ;;
            --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
            --tag)            IMAGE_TAG="$2";      shift 2 ;;
            --http)           SCHEME="http";       shift ;;
            --https)          SCHEME="https";      shift ;;
            --no-docker-install) AUTO_DOCKER=0;    shift ;;
            --uninstall)      UNINSTALL=1;         shift ;;
            --yes|-y)         ASSUME_YES=1;        shift ;;
            --help|-h)        show_help; exit 0 ;;
            *)                die "Opsi tidak dikenal: $1 (coba --help)" ;;
        esac
    done

    init_tty
    detect_os
    [ -n "$DIR" ] || DIR="$(default_dir)"

    printf '\n%s┌─ SCADA HMI Builder & Universal Gateway ─┐%s\n' "$CYN" "$RST"
    printf '%s│  installer v%-27s │%s\n' "$CYN" "$SCADA_VERSION" "$RST"
    printf '%s└─────────────────────────────────────────┘%s\n' "$CYN" "$RST"

    ensure_docker

    if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; fi

    step "2/7  Direktori & jaringan"
    if ! mkdir -p "$DIR" 2>/dev/null; then
        [ -n "$SUDO" ] || die "Tidak bisa membuat $DIR dan sudo tidak tersedia."
        $SUDO mkdir -p "$DIR"
        $SUDO chown "$(id -u):$(id -g)" "$DIR"
    fi
    cd "$DIR"
    mkdir -p license backups infra/caddy
    ok "Direktori instalasi: $DIR"

    if [ -f .env ]; then
        # Upgrade: .env dipertahankan, jadi alamat dan port dibaca dari sana —
        # deteksi ulang bisa menghasilkan nilai lain dari yang sedang dipakai
        # kontainer yang berjalan.
        REUSED_ENV=1
        if [ -n "$HOST" ] || [ -n "$HTTP_PORT" ]; then
            warn "--host/--port diabaikan pada upgrade. Sunting .env lalu jalankan: scada restart"
        fi
        PUBLIC_URL="$(env_value PUBLIC_URL)"
        HTTP_PORT="$(env_value HTTP_PORT)"
        SITE_ADDRESS="$(env_value SITE_ADDRESS)"
        : "${PUBLIC_URL:=http://localhost}"
        : "${HTTP_PORT:=80}"
    fi

    [ -n "$HOST" ] || HOST="$(detect_ip)"

    if [ -z "$HTTP_PORT" ]; then
        HTTP_PORT=80
        if port_busy 80; then
            HTTP_PORT=8080
            if port_busy 8080; then HTTP_PORT=8088; fi
            warn "Port 80 sudah dipakai — memakai port $HTTP_PORT"
        fi
    fi
    if [ "$REUSED_ENV" -eq 0 ] && [ "$SCHEME" = "https" ] && port_busy 443; then
        HTTPS_PORT=8443
        warn "Port 443 sudah dipakai — memakai port $HTTPS_PORT"
    fi

    if [ "$REUSED_ENV" -eq 1 ]; then
        ok "Alamat server: $PUBLIC_URL ${DIM}(dari .env yang sudah ada)${RST}"
    elif [ "$SCHEME" = "https" ]; then
        SITE_ADDRESS="https://${HOST}"
        PUBLIC_URL="$SITE_ADDRESS"
        if [ "$HTTPS_PORT" != "443" ]; then PUBLIC_URL="https://${HOST}:${HTTPS_PORT}"; fi
        ok "Alamat server: $PUBLIC_URL"
    else
        # Caddy mendengar di port 80 dalam kontainer apa pun port host-nya, dan
        # blok `:80` cocok dengan Host apa pun — IP, hostname, maupun berport.
        SITE_ADDRESS=":80"
        PUBLIC_URL="http://${HOST}"
        if [ "$HTTP_PORT" != "80" ]; then PUBLIC_URL="http://${HOST}:${HTTP_PORT}"; fi
        ok "Alamat server: $PUBLIC_URL"
    fi

    step "3/7  Akun admin"
    if [ -f .env ]; then
        ok "Instalasi lama terdeteksi — .env dipertahankan, admin tidak dibuat ulang"
    else
        FRESH=1
        if [ "$ASSUME_YES" -eq 1 ]; then
            [ -n "$ADMIN_EMAIL" ] || die "--admin-email wajib diisi bersama --yes"
            [ "${#ADMIN_PASSWORD}" -ge 8 ] || die "--admin-password minimal 8 karakter"
        else
            while [ -z "$ADMIN_EMAIL" ]; do ADMIN_EMAIL="$(ask 'Email admin:')"; done
            while [ "${#ADMIN_PASSWORD}" -lt 8 ]; do
                ADMIN_PASSWORD="$(ask_secret 'Kata sandi admin (min. 8 karakter):')"
                if [ "${#ADMIN_PASSWORD}" -lt 8 ]; then warn "Terlalu pendek, coba lagi."; fi
            done
        fi
        write_env
        ok "Konfigurasi dan rahasia dibuat"
    fi

    write_compose
    write_caddyfile

    step "4/7  Mengunduh image ($IMAGE_TAG)"
    dc pull
    ok "Image siap"

    step "5/7  Database"
    dc up -d --wait db redis
    dc run --rm api alembic upgrade head
    dc run --rm api python -m app.db.seed
    ok "Skema dan data awal siap"

    if [ "$FRESH" -eq 1 ]; then
        dc run --rm \
            -e "BOOTSTRAP_ORG_NAME=$ORG_NAME" \
            -e "BOOTSTRAP_ADMIN_NAME=$ADMIN_NAME" \
            -e "BOOTSTRAP_ADMIN_EMAIL=$ADMIN_EMAIL" \
            -e "BOOTSTRAP_ADMIN_PASSWORD=$ADMIN_PASSWORD" \
            api python -m app.db.bootstrap
        ok "Akun admin dibuat: $ADMIN_EMAIL"
    fi

    step "6/7  Menyalakan layanan"
    dc up -d
    printf '%s· Menunggu antarmuka siap%s' "$CYN" "$RST"
    if have curl; then
        i=0
        while [ "$i" -lt 60 ]; do
            if curl -fsS --max-time 2 "http://127.0.0.1:${HTTP_PORT}/health" > /dev/null 2>&1; then
                break
            fi
            sleep 2; i=$((i + 1)); printf '.'
        done
    fi
    printf '\n'
    ok "Semua layanan berjalan"

    step "7/7  Perintah scada"
    write_cli
    ok "Terpasang: $CLI_PATH"

    printf '\n%s%s%s\n' "$GRN" "  ✔  SCADA siap dipakai" "$RST"
    printf '\n'
    printf '     Buka       %s%s%s\n' "$BLD" "$PUBLIC_URL" "$RST"
    if [ -n "$ADMIN_EMAIL" ]; then printf '     Login      %s\n' "$ADMIN_EMAIL"; fi
    printf '     Kelola     %sscada%s  (start, stop, logs, update, backup)\n' "$BLD" "$RST"
    printf '\n'
    printf '     %sLangkah berikutnya: buat agen di UI → Agen → salin kode → jalankan%s\n' "$DIM" "$RST"
    printf '     %sscada enroll enr_xxxx%s\n\n' "$DIM" "$RST"

    case "$CLI_PATH" in
        "$HOME/.local/bin/scada")
            case ":$PATH:" in
                *":$HOME/.local/bin:"*) ;;
                *) warn "Tambahkan ke PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
            esac ;;
        "$DIR/scada") warn "Jalankan lewat: $DIR/scada" ;;
    esac
}

main "$@"
