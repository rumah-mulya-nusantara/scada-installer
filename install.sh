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
#   --auto-update on|off    pembaruan otomatis harian (default: on)
#   --update-at HH:MM       jam pembaruan otomatis (default: 02:30)
#   --https                 aktifkan TLS internal Caddy
#   --no-docker-install     jangan pasang Docker otomatis
#   --yes, -y               jangan bertanya apa pun
#   --uninstall             hapus instalasi
#
set -euo pipefail

SCADA_VERSION="2.1.2"

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

local_ips() {
    case "$OS" in
        macos) ifconfig 2>/dev/null | awk '/inet /{print $2}' ;;
        linux)
            if have ip; then
                ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
            else
                ifconfig 2>/dev/null | awk '/inet /{print $2}' | sed 's/addr://'
            fi ;;
    esac
}

url_host() {
    h="${1#*://}"; h="${h%%/*}"; printf '%s' "${h%%:*}"
}

url_port() {
    h="${1#*://}"; h="${h%%/*}"
    case "$h" in *:*) printf '%s' "${h##*:}" ;; esac
}

is_ipv4() {
    printf '%s' "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

# Alamat di .env dibekukan dari pemasangan sebelumnya. Bila DHCP sudah memberi
# mesin ini alamat lain, pemasang akan menyuruh membuka alamat yang tidak
# menjawab — persis seperti instalasi gagal, padahal seluruh layanan sehat.
check_address_drift() {
    local host port actual ws found ip
    host="$(url_host "$PUBLIC_URL")"
    if ! is_ipv4 "$host"; then return 0; fi
    case "$host" in 127.*) return 0 ;; esac

    found=0
    for ip in $(local_ips); do
        if [ "$ip" = "$host" ]; then found=1; break; fi
    done
    if [ "$found" -eq 1 ]; then return 0; fi

    actual="$(detect_ip)"
    if [ "$actual" = "localhost" ] || [ "$actual" = "$host" ]; then
        warn "Alamat di .env ($host) bukan alamat mesin ini, dan alamat baru tidak terdeteksi."
        warn "Akses lewat http://localhost bila membuka dari mesin ini sendiri."
        return 0
    fi

    port="$(url_port "$PUBLIC_URL")"
    if [ -n "$port" ]; then
        actual="$actual:$port"
    fi

    # SITE_ADDRESS `:80` cocok dengan host apa pun, jadi alamat di .env hanya
    # dipakai untuk ditampilkan — aman ditulis ulang. Pemasangan https lain
    # perkara: nama host-nya ikut menentukan sertifikat.
    if [ "$(env_value SITE_ADDRESS)" = ":80" ]; then
        ws="$(printf 'http://%s' "$actual" | sed 's|^http|ws|')"
        env_set PUBLIC_URL "http://$actual"
        env_set CORS_ORIGINS "http://$actual"
        env_set NEXT_PUBLIC_WS_URL "$ws"
        PUBLIC_URL="http://$actual"
        ADDRESS_FIXED=1
        warn "Alamat mesin berubah ($host → $actual). .env diperbarui otomatis."
    else
        warn "Alamat di .env ($host) bukan lagi alamat mesin ini — sekarang $actual."
        warn "Pemasangan https terikat nama host, jadi .env tidak diubah otomatis."
        warn "Sunting SITE_ADDRESS/PUBLIC_URL/CORS_ORIGINS lalu jalankan: scada restart"
    fi
}

env_value() {
    [ -f .env ] || return 0
    sed -n "s/^$1=//p" .env | head -1
}

env_set() {
    if grep -q "^$1=" .env 2>/dev/null; then
        sed -i.bak "s|^$1=.*|$1=$2|" .env && rm -f .env.bak
    else
        printf '%s=%s\n' "$1" "$2" >> .env
    fi
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
# Nama project Docker Compose. Berdiri sendiri supaya pemasangan ini tidak pernah
# berbagi container atau volume dengan stack lain di mesin yang sama — misalnya
# checkout pengembangan, yang compose-nya memakai nama bawaan yang sama.
# Instalasi lama tidak punya baris ini dan tetap memakai nama bawaan itu, jadi
# volumenya tidak berpindah.
COMPOSE_PROJECT_NAME=scada-onprem

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

# Diisi otomatis oleh installer (agen "Agen Lokal"), atau: scada enroll enr_xxxx
AGENT_ENROLLMENT_CODE=
AGENT_LOG_LEVEL=INFO

LICENSE_FILE=/srv/license/license.key
LICENSE_PORTAL_URL=$LICENSE_PORTAL_URL
IMAGE_TAG=$IMAGE_TAG

# Pembaruan otomatis harian. Matikan di instalasi air-gapped: scada autoupdate off
AUTO_UPDATE=$AUTO_UPDATE
AUTO_UPDATE_AT=$AUTO_UPDATE_AT
ENV
    umask 022
}

write_cli() {
    printf '#!/usr/bin/env bash\nSCADA_DIR="%s"\nSCADA_COMPOSE="%s"\nSCADA_DOCKER="%s"\n' "$DIR" "$COMPOSE" "$DOCKER" > scada
    cat >> scada <<'CLI'
set -euo pipefail
cd "$SCADA_DIR"

GRN=''; RED=''; YLW=''; CYN=''; DIM=''; RST=''
if [ -t 1 ]; then
    GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'
    CYN=$'\033[36m'; DIM=$'\033[2m'; RST=$'\033[0m'
fi
ok()   { printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s·%s %s\n' "$CYN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YLW" "$RST" "$*"; }
err()  { printf '%s✘%s %s\n' "$RED" "$RST" "$*" >&2; }

dc() { $SCADA_COMPOSE -f docker-compose.prod.yml "$@"; }
dk() { $SCADA_DOCKER "$@"; }

env_value() { sed -n "s/^$1=//p" .env 2>/dev/null | head -1; }
env_set() {
    if grep -q "^$1=" .env 2>/dev/null; then
        sed -i.bak "s|^$1=.*|$1=$2|" .env && rm -f .env.bak
    else
        printf '%s=%s\n' "$1" "$2" >> .env
    fi
}
url() { env_value PUBLIC_URL; }

# Sidik jari image yang dipakai stack saat ini. Dibandingkan dengan yang
# terakhir berhasil dipasang, bukan dengan keadaan sebelum pull, supaya
# pembaruan yang gagal di tengah jalan dicoba lagi pada jadwal berikutnya.
image_state() {
    dc config --images 2>/dev/null | sort -u | while IFS= read -r img; do
        printf '%s %s\n' "$img" "$(dk image inspect --format '{{.Id}}' "$img" 2>/dev/null || echo belum)"
    done
}

applied_state() { cat .update-state 2>/dev/null || true; }

wait_healthy() {
    local port i
    port="$(env_value HTTP_PORT)"; : "${port:=80}"
    command -v curl > /dev/null 2>&1 || return 0
    i=0
    while [ "$i" -lt 45 ]; do
        curl -fsS --max-time 2 "http://127.0.0.1:${port}/health" > /dev/null 2>&1 && return 0
        sleep 2; i=$((i + 1))
    done
    return 1
}

backup_db() {
    local f
    mkdir -p backups
    f="backups/scada-$(date -u +%Y%m%dT%H%M%SZ).dump"
    dc exec -T db pg_dump -U scada -Fc scada > "$f"
    cp .env "$f.env"
    printf '%s\n' "$f"
}

apply_update() {
    local keep_backup="${1:-yes}" dump=""
    info "Menarik image terbaru..."
    dc pull
    if [ "$keep_backup" = "yes" ] && [ -n "$(dc ps -q db 2>/dev/null)" ]; then
        info "Mencadangkan database dulu..."
        dump="$(backup_db)"
        ok "Cadangan: $dump"
    fi
    dc up -d --wait db redis
    info "Migrasi database..."
    dc run --rm -T api alembic upgrade head
    info "Menyalakan ulang layanan..."
    dc up -d
    image_state > .update-state
    if wait_healthy; then
        ok "Pembaruan selesai — $(url)"
    else
        err "Layanan belum sehat setelah pembaruan. Periksa: scada logs api"
        [ -n "$dump" ] && err "Pulihkan bila perlu: scada restore $dump"
        return 1
    fi
}

# ── Pembaruan otomatis ───────────────────────────────────────────────────────
update_time()  { local t; t="$(env_value AUTO_UPDATE_AT)"; printf '%s' "${t:-02:30}"; }
sudo_if_needed() { if [ "$(id -u)" -ne 0 ] && command -v sudo > /dev/null 2>&1; then printf 'sudo'; fi; }
has_systemd()  { command -v systemctl > /dev/null 2>&1 && [ -d /etc/systemd/system ]; }

enable_autoupdate() {
    local at hh mm sudo_cmd
    at="$(update_time)"; hh="${at%%:*}"; mm="${at##*:}"
    env_set AUTO_UPDATE on
    env_set AUTO_UPDATE_AT "$at"
    image_state > .update-state

    if has_systemd; then
        sudo_cmd="$(sudo_if_needed)"
        $sudo_cmd tee /etc/systemd/system/scada-update.service > /dev/null <<UNIT
[Unit]
Description=Pembaruan otomatis SCADA
After=docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$SCADA_DIR
ExecStart=$SCADA_DIR/scada _autoupdate
UNIT
        $sudo_cmd tee /etc/systemd/system/scada-update.timer > /dev/null <<UNIT
[Unit]
Description=Jadwal pembaruan otomatis SCADA

[Timer]
OnCalendar=*-*-* $hh:$mm:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        $sudo_cmd systemctl daemon-reload
        $sudo_cmd systemctl enable --now scada-update.timer > /dev/null
        ok "Pembaruan otomatis aktif (systemd timer, sekitar pukul $at)"
    elif command -v crontab > /dev/null 2>&1; then
        local lain
        lain="$(crontab -l 2>/dev/null | grep -v 'scada _autoupdate' || true)"
        {
            if [ -n "$lain" ]; then printf '%s\n' "$lain"; fi
            printf '%s %s * * * %s _autoupdate\n' "$mm" "$hh" "$SCADA_DIR/scada"
        } | crontab -
        ok "Pembaruan otomatis aktif (cron, pukul $at)"
    else
        env_set AUTO_UPDATE off
        err "Tidak ada systemd maupun cron — jadwalkan sendiri: $SCADA_DIR/scada _autoupdate"
        return 1
    fi
}

disable_autoupdate() {
    local sudo_cmd
    env_set AUTO_UPDATE off
    if has_systemd && [ -f /etc/systemd/system/scada-update.timer ]; then
        sudo_cmd="$(sudo_if_needed)"
        $sudo_cmd systemctl disable --now scada-update.timer > /dev/null 2>&1 || true
        $sudo_cmd rm -f /etc/systemd/system/scada-update.timer /etc/systemd/system/scada-update.service
        $sudo_cmd systemctl daemon-reload
    fi
    if command -v crontab > /dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'scada _autoupdate'; then
        local lain
        lain="$(crontab -l 2>/dev/null | grep -v 'scada _autoupdate' || true)"
        printf '%s' "${lain:+$lain
}" | crontab - 2>/dev/null || true
    fi
    ok "Pembaruan otomatis dimatikan"
}

status_autoupdate() {
    local state
    state="$(env_value AUTO_UPDATE)"; : "${state:=off}"
    printf '  status   %s\n' "$state"
    printf '  jadwal   sekitar pukul %s setiap hari\n' "$(update_time)"
    if has_systemd && [ -f /etc/systemd/system/scada-update.timer ]; then
        printf '  mekanis  systemd timer\n'
        systemctl list-timers scada-update.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/  berikut  /'
    elif command -v crontab > /dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'scada _autoupdate'; then
        printf '  mekanis  cron\n'
    else
        printf '  mekanis  belum terjadwal\n'
    fi
    if [ -f update.log ]; then
        printf '\n  catatan terakhir:\n'
        tail -n 8 update.log | sed 's/^/    /'
    fi
}

run_autoupdate() {
    exec >> "$SCADA_DIR/update.log" 2>&1
    printf '\n=== %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$(env_value AUTO_UPDATE)" != "on" ]; then
        echo "pembaruan otomatis nonaktif — dilewati"
        exit 0
    fi
    if ! dc pull -q; then
        echo "registry tidak terjangkau — dicoba lagi pada jadwal berikutnya"
        exit 0
    fi
    if [ "$(image_state)" = "$(applied_state)" ]; then
        echo "sudah versi terbaru"
        exit 0
    fi
    echo "versi baru ditemukan — memasang"
    apply_update yes
}

check_update() {
    info "Memeriksa versi terbaru..."
    if ! dc pull -q; then
        err "Registry tidak terjangkau."
        return 1
    fi
    if [ "$(image_state)" = "$(applied_state)" ]; then
        ok "Sudah versi terbaru."
        return 0
    fi
    warn "Ada versi baru. Pasang dengan: scada update"
    return 0
}

case "${1:-help}" in
    start)     dc up -d ;;
    stop)      dc stop ;;
    restart)   dc up -d --force-recreate ;;
    status|ps) dc ps ;;
    logs)      shift; dc logs -f --tail=100 "$@" ;;
    url)       url ;;
    open)
        u="$(url)"
        command -v open     > /dev/null 2>&1 && open "$u"     && exit 0
        command -v xdg-open > /dev/null 2>&1 && xdg-open "$u" && exit 0
        printf '%s\n' "$u" ;;
    update)
        if [ "${2:-}" = "--check" ]; then check_update; else apply_update yes; fi ;;
    autoupdate)
        case "${2:-status}" in
            on)  enable_autoupdate ;;
            off) disable_autoupdate ;;
            *)   status_autoupdate ;;
        esac ;;
    _autoupdate) run_autoupdate ;;
    doctor)
        printf '%sPemeriksaan SCADA%s — %s\n\n' "$CYN" "$RST" "$SCADA_DIR"
        printf 'Kontainer\n'; dc ps; printf '\n'
        port="$(env_value HTTP_PORT)"; : "${port:=80}"
        printf 'Antarmuka\n'
        if command -v curl > /dev/null 2>&1 && curl -fsS --max-time 3 "http://127.0.0.1:${port}/health" > /dev/null 2>&1; then
            ok "http://127.0.0.1:${port}/health menjawab"
        else
            err "http://127.0.0.1:${port}/health tidak menjawab"
        fi
        printf '\nAkun\n'
        orgs="$(dc exec -T db psql -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" \
                  -tAc 'select count(*) from organizations' 2>/dev/null | tr -d ' \r' || true)"
        users="$(dc exec -T db psql -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" \
                  -tAc 'select count(*) from users' 2>/dev/null | tr -d ' \r' || true)"
        if [ -z "$orgs" ]; then
            err "Database belum bisa dibaca — migrasi mungkin belum jalan: scada logs db"
        elif [ "$orgs" = "0" ] || [ "$users" = "0" ]; then
            err "Belum ada organisasi/admin — itu sebabnya login ditolak."
            printf '    Buat sekarang:\n'
            printf "      scada create-admin email@anda.co.id 'KataSandiMin8'\n"
        else
            ok "$orgs organisasi, $users pengguna"
            dc exec -T db psql -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" \
                -tAc 'select email, role, status from users order by created_at limit 5' 2>/dev/null | sed 's/^/    /'
        fi
        printf '\nGalat terakhir di api\n'
        dc logs --tail=30 api 2>&1 | grep -iE 'error|traceback|exception|critical' | tail -8 | sed 's/^/    /' || true
        printf '\n' ;;
    reset-password)
        email="${2:-}"; pass="${3:-}"
        if [ -z "$email" ] || [ -z "$pass" ]; then
            err "Pemakaian: scada reset-password email@anda.co.id 'KataSandiMin8'"; exit 1
        fi
        dc run --rm -T -e "RESET_EMAIL=$email" -e "RESET_PASSWORD=$pass" \
            api python - < "$SCADA_DIR/reset_password.py"
        ok "Coba login sebagai $email" ;;
    create-admin)
        email="${2:-}"; pass="${3:-}"
        if [ -z "$email" ] || [ -z "$pass" ]; then
            err "Pemakaian: scada create-admin email@anda.co.id 'KataSandiMin8'"; exit 1
        fi
        dc run --rm -T \
            -e "BOOTSTRAP_ORG_NAME=$(env_value BOOTSTRAP_ORG_NAME)" \
            -e "BOOTSTRAP_ADMIN_EMAIL=$email" \
            -e "BOOTSTRAP_ADMIN_PASSWORD=$pass" \
            api python -m app.db.bootstrap
        : > .bootstrap-done
        ok "Selesai. Coba login sebagai $email" ;;
    enroll)
        code="${2:-}"
        [ -n "$code" ] || { err "Sertakan kode: scada enroll enr_xxxx"; exit 1; }
        env_set AGENT_ENROLLMENT_CODE "$code"
        dc up -d --force-recreate agent
        ok "Agent didaftarkan. Pantau: scada logs agent" ;;
    backup)
        f="$(backup_db)"
        ok "Cadangan: $f ${DIM}(.env ikut disalin — wajib untuk membuka kredensial device)${RST}" ;;
    restore)
        f="${2:-}"
        [ -f "$f" ] || { err "Berkas dump tidak ditemukan: $f"; exit 1; }
        dc exec -T db pg_restore -U scada -d scada --clean --if-exists < "$f"
        ok "Dipulihkan dari $f" ;;
    uninstall)
        printf 'Hapus SELURUH data SCADA di %s? Ketik "hapus" untuk lanjut: ' "$SCADA_DIR"
        read -r c
        [ "$c" = "hapus" ] || { echo "Dibatalkan."; exit 1; }
        disable_autoupdate || true
        dc down -v
        ok "Kontainer dan volume dihapus. Sisa berkas ada di $SCADA_DIR" ;;
    *)
        printf '%sSCADA%s — %s\n\n' "$CYN" "$RST" "$SCADA_DIR"
        printf '  scada start | stop | restart | status\n'
        printf '  scada logs [layanan]      ikuti log (api, web, worker, agent, db)\n'
        printf '  scada open | url          buka antarmuka\n'
        printf '  scada update              pasang versi terbaru sekarang\n'
        printf '  scada update --check      lihat apakah ada versi baru\n'
        printf '  scada autoupdate on|off   pembaruan otomatis harian\n'
        printf '  scada autoupdate          status dan jadwalnya\n'
        printf '  scada doctor              periksa kenapa tidak bisa dipakai\n'
        printf '  scada create-admin <email> <sandi>   buat admin pertama\n'
        printf '  scada reset-password <email> <sandi>  ganti kata sandi\n'
        printf '  scada enroll enr_xxxx     daftarkan edge agent\n'
        printf '  scada backup              cadangkan database + .env\n'
        printf '  scada restore <berkas>    pulihkan dari cadangan\n'
        printf '  scada uninstall           hapus kontainer dan volume\n\n' ;;
esac
CLI
    chmod +x scada

    cat > reset_password.py <<'PYFILE'
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
PYFILE

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
  --auto-update on|off    pembaruan otomatis harian (default: on)
  --update-at HH:MM       jam pembaruan otomatis (default: 02:30)
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
# Alamat portal aktivasi vendor. Hanya ditampilkan sebagai tautan di halaman
# Lisensi; server ini tidak pernah menghubunginya. Kosong = tautan tidak muncul,
# dan halaman itu menyuruh pelanggan mengirim kode ke vendor lewat jalur apa pun.
LICENSE_PORTAL_URL="${SCADA_LICENSE_PORTAL_URL:-}"
AUTO_UPDATE="${SCADA_AUTO_UPDATE:-}"
AUTO_UPDATE_AT="${SCADA_UPDATE_AT:-02:30}"
ASSUME_YES=0
AUTO_DOCKER=1
UNINSTALL=0
CLI_PATH=""
SITE_ADDRESS=""
PUBLIC_URL=""
FRESH=0
REUSED_ENV=0
HEALTHY=2
AGENT_PROVISIONED=0
ADDRESS_FIXED=0

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
            --portal)         LICENSE_PORTAL_URL="$2"; shift 2 ;;
            --auto-update)    AUTO_UPDATE="$2";    shift 2 ;;
            --no-auto-update) AUTO_UPDATE="off";   shift ;;
            --update-at)      AUTO_UPDATE_AT="$2"; shift 2 ;;
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
        check_address_drift
        if [ "$ADDRESS_FIXED" -eq 1 ]; then
            ok "Alamat server: $PUBLIC_URL ${DIM}(dideteksi ulang)${RST}"
        else
            ok "Alamat server: $PUBLIC_URL ${DIM}(dari .env yang sudah ada)${RST}"
        fi
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
        ok "Konfigurasi lama terdeteksi — .env dipertahankan"
        if ! grep -q '^AUTO_UPDATE=' .env; then
            printf '\n# Pembaruan otomatis harian. Matikan di instalasi air-gapped: scada autoupdate off\nAUTO_UPDATE=%s\nAUTO_UPDATE_AT=%s\n' \
                "${AUTO_UPDATE:-on}" "$AUTO_UPDATE_AT" >> .env
        elif [ -n "$AUTO_UPDATE" ]; then
            sed -i.bak "s|^AUTO_UPDATE=.*|AUTO_UPDATE=$AUTO_UPDATE|" .env && rm -f .env.bak
        fi
        AUTO_UPDATE="$(env_value AUTO_UPDATE)"
    fi

    # Adanya .env tidak membuktikan instalasi selesai: instalasi yang mati di
    # tengah jalan meninggalkan .env tanpa akun admin. Yang membuktikannya
    # adalah penanda ini, atau kontainer api dari instalasi sebelum penanda ada.
    if [ -f .bootstrap-done ]; then
        FRESH=0
    elif [ -n "$(dc ps -aq api 2>/dev/null)" ]; then
        : > .bootstrap-done
        FRESH=0
    else
        FRESH=1
    fi

    if [ "$FRESH" -eq 0 ]; then
        ok "Akun admin sudah ada — tidak dibuat ulang"
    elif [ "$ASSUME_YES" -eq 1 ]; then
        [ -n "$ADMIN_EMAIL" ] || die "--admin-email wajib diisi bersama --yes"
        [ "${#ADMIN_PASSWORD}" -ge 8 ] || die "--admin-password minimal 8 karakter"
    else
        while [ -z "$ADMIN_EMAIL" ]; do ADMIN_EMAIL="$(ask 'Email admin:')"; done
        while [ "${#ADMIN_PASSWORD}" -lt 8 ]; do
            ADMIN_PASSWORD="$(ask_secret 'Kata sandi admin (min. 8 karakter):')"
            if [ "${#ADMIN_PASSWORD}" -lt 8 ]; then warn "Terlalu pendek, coba lagi."; fi
        done
    fi

    if [ ! -f .env ]; then
        if [ -z "$AUTO_UPDATE" ]; then
            if [ "$ASSUME_YES" -eq 1 ]; then
                AUTO_UPDATE="on"
            elif confirm "Pasang pembaruan otomatis setiap malam pukul $AUTO_UPDATE_AT?"; then
                AUTO_UPDATE="on"
            else
                AUTO_UPDATE="off"
            fi
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
    dc run --rm -T api alembic upgrade head
    dc run --rm -T api python -m app.db.seed
    ok "Skema dan data awal siap"

    if [ "$FRESH" -eq 1 ]; then
        dc run --rm -T \
            -e "BOOTSTRAP_ORG_NAME=$ORG_NAME" \
            -e "BOOTSTRAP_ADMIN_NAME=$ADMIN_NAME" \
            -e "BOOTSTRAP_ADMIN_EMAIL=$ADMIN_EMAIL" \
            -e "BOOTSTRAP_ADMIN_PASSWORD=$ADMIN_PASSWORD" \
            api python -m app.db.bootstrap
        : > .bootstrap-done
        ok "Akun admin dibuat: $ADMIN_EMAIL"
    fi

    # Tanpa kode enrolment kontainer agen keluar dengan galat dan direstart
    # terus-menerus. Agen di satu server tidak perlu ritual salin-kode dari UI,
    # jadi installer yang menyiapkannya.
    AGENT_PROVISIONED=0
    agent_out="$(mktemp)"; agent_err="$(mktemp)"
    if dc run --rm -T api python -m app.db.provision_agent > "$agent_out" 2> "$agent_err"; then
        agent_code="$(tr -d '\r' < "$agent_out" | grep -oE '^enr_[A-Za-z0-9_-]+$' | head -1 || true)"
        if [ -n "$agent_code" ]; then
            env_set AGENT_ENROLLMENT_CODE "$agent_code"
            AGENT_PROVISIONED=1
            ok "Agen lokal disiapkan"
        else
            AGENT_PROVISIONED=1
            ok "Agen lokal sudah terdaftar"
        fi
    else
        warn "Penyiapan agen lokal gagal — daftarkan lewat UI → Agen, lalu: scada enroll enr_xxxx"
        sed 's/^/    /' "$agent_err" >&2
    fi
    rm -f "$agent_out" "$agent_err"

    step "6/7  Menyalakan layanan"
    dc up -d
    printf '%s· Menunggu antarmuka siap%s' "$CYN" "$RST"
    HEALTHY=2
    if have curl; then
        HEALTHY=0
        i=0
        while [ "$i" -lt 60 ]; do
            if curl -fsS --max-time 2 "http://127.0.0.1:${HTTP_PORT}/health" > /dev/null 2>&1; then
                HEALTHY=1; break
            fi
            sleep 2; i=$((i + 1)); printf '.'
        done
    fi
    printf '\n'
    if [ "$AGENT_PROVISIONED" -eq 1 ]; then
        i=0
        while [ "$i" -lt 20 ]; do
            if dc logs agent 2>/dev/null | grep -qE 'Enrolment berhasil|Kunci agen dimuat'; then
                break
            fi
            sleep 3; i=$((i + 1))
        done
        if [ "$i" -lt 20 ]; then
            ok "Agen lokal terhubung"
        else
            AGENT_PROVISIONED=0
            warn "Agen lokal belum terhubung — periksa: scada logs agent"
        fi
    fi

    case "$HEALTHY" in
        1) ok "Semua layanan berjalan" ;;
        2) warn "curl tidak tersedia — status layanan tidak diperiksa" ;;
        *) err "Layanan belum menjawab setelah 2 menit."
           dc ps
           err "Lihat sebabnya: $DIR/scada logs api" ;;
    esac

    step "7/7  Perintah scada"
    write_cli
    ok "Terpasang: $CLI_PATH"

    if [ "${AUTO_UPDATE:-off}" = "on" ]; then
        if ! ./scada autoupdate on; then
            AUTO_UPDATE="off"
            warn "Penjadwalan gagal — jalankan sendiri nanti: scada autoupdate on"
        fi
    else
        ./scada autoupdate off > /dev/null 2>&1 || true
        ok "Pembaruan otomatis mati — pasang manual dengan: scada update"
    fi

    if [ "$HEALTHY" -eq 0 ]; then
        printf '\n%s%s%s\n' "$YLW" "  !  SCADA terpasang tetapi belum menjawab — jalankan: scada doctor" "$RST"
    else
        printf '\n%s%s%s\n' "$GRN" "  ✔  SCADA siap dipakai" "$RST"
    fi
    printf '\n'
    printf '     Buka       %s%s%s\n' "$BLD" "$PUBLIC_URL" "$RST"
    if [ -n "$ADMIN_EMAIL" ]; then printf '     Login      %s\n' "$ADMIN_EMAIL"; fi
    printf '     Kelola     %sscada%s  (start, stop, logs, update, backup)\n' "$BLD" "$RST"
    if [ "${AUTO_UPDATE:-off}" = "on" ]; then
        printf '     Pembaruan  otomatis tiap malam pukul %s  %s(scada autoupdate off untuk mematikan)%s\n' \
            "$AUTO_UPDATE_AT" "$DIM" "$RST"
    fi
    printf '\n'
    # Tanpa baris ini pemasang tidak pernah tahu ada hitungan mundur yang sudah
    # berjalan; yang ia temukan nanti hanya penolakan 402 saat menambah device.
    printf '     %sLisensi   %sMode DEMO, hitungannya sudah mulai: 2 device, 100 tag, 2 user.%s\n' \
        "$BLD" "$DIM" "$RST"
    if [ -n "$LICENSE_PORTAL_URL" ]; then
        printf '               %sAktifkan: menu Lisensi → Salin kode → ajukan di%s\n' "$DIM" "$RST"
        printf '               %s%s%s\n' "$BLD" "$LICENSE_PORTAL_URL" "$RST"
    else
        printf '               %sAktifkan: menu Lisensi → Salin kode → kirim ke vendor.%s\n' "$DIM" "$RST"
        printf '               %sServer ini tidak menghubungi siapa pun.%s\n' "$DIM" "$RST"
    fi
    printf '\n'
    if [ "$AGENT_PROVISIONED" -eq 1 ]; then
        printf '     %sEdge agent "Agen Lokal" sudah berjalan — tinggal tambahkan device di UI.%s\n' "$DIM" "$RST"
        printf '     %sAgen di komputer lain: UI → Agen → salin kode → scada enroll enr_xxxx%s\n\n' "$DIM" "$RST"
    else
        printf '     %sLangkah berikutnya: buat agen di UI → Agen → salin kode → jalankan%s\n' "$DIM" "$RST"
        printf '     %sscada enroll enr_xxxx%s\n\n' "$DIM" "$RST"
    fi

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
