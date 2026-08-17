#!/usr/bin/env bash
#
# Pemasang SCADA HMI Builder & Universal Gateway.
#
#   ./install.sh                                   interaktif
#   ./install.sh --admin-email a@b.c --admin-password 'Rahasia123'
#   ./install.sh --http                            tanpa TLS (default untuk jaringan lokal)
#   ./install.sh --tag v1.2.3                      versi image tertentu
#   ./install.sh --yes                             non-interaktif (wajib --admin-email & --admin-password)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

COMPOSE=(docker compose -f docker-compose.prod.yml)
ENV_FILE="$ROOT/.env"

MODE="onprem"
SCHEME="http"       # default http — paling mudah untuk jaringan lokal
HOST=""
ORG_NAME="SCADA"
ADMIN_NAME="Administrator"
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
IMAGE_TAG="latest"
ASSUME_YES=0

c_ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m·\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✘\033[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

usage() { sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)           HOST="$2";           shift 2 ;;
        --org)            ORG_NAME="$2";        shift 2 ;;
        --admin-name)     ADMIN_NAME="$2";      shift 2 ;;
        --admin-email)    ADMIN_EMAIL="$2";     shift 2 ;;
        --admin-password) ADMIN_PASSWORD="$2";  shift 2 ;;
        --mode)           MODE="$2";            shift 2 ;;
        --http)           SCHEME="http";        shift ;;
        --https)          SCHEME="https";       shift ;;
        --tag)            IMAGE_TAG="$2";       shift 2 ;;
        --yes|-y)         ASSUME_YES=1;         shift ;;
        --help|-h)        usage ;;
        *)                die "Opsi tidak dikenal: $1 (coba --help)" ;;
    esac
done

# ── 1. Prasyarat ─────────────────────────────────────────────────────────────
echo
c_info "Memeriksa prasyarat..."
command -v docker  > /dev/null 2>&1 || die "Docker belum terpasang. https://docs.docker.com/engine/install/"
docker compose version > /dev/null 2>&1 || die "Plugin 'docker compose' v2 tidak tersedia."
docker info > /dev/null 2>&1 || die "Docker daemon tidak berjalan."
command -v openssl > /dev/null 2>&1 || die "openssl tidak tersedia."
c_ok "Docker $(docker version --format '{{.Server.Version}}') siap"

# ── 2. Alamat server (auto-detect) ───────────────────────────────────────────
detect_ip() {
    if command -v ip > /dev/null 2>&1; then
        ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}'
    elif command -v ipconfig > /dev/null 2>&1; then
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
    fi
}

if [[ -z "$HOST" ]]; then
    HOST="$(detect_ip || true)"
    HOST="${HOST:-localhost}"
fi

SITE_ADDRESS="${SCHEME}://${HOST}"
WS_URL="$(echo "$SCHEME" | sed 's/http/ws/')://${HOST}"

c_ok "Alamat server terdeteksi: $SITE_ADDRESS"

# ── 3. Akun admin (hanya tanya email & password) ─────────────────────────────
echo
if [[ $ASSUME_YES -eq 0 ]]; then
    if [[ -z "$ADMIN_EMAIL" ]]; then
        read -rp "Email admin: " ADMIN_EMAIL
    fi
    if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
        while [[ ${#ADMIN_PASSWORD} -lt 8 ]]; do
            read -rsp "Kata sandi admin (min. 8 karakter): " ADMIN_PASSWORD; echo
            [[ ${#ADMIN_PASSWORD} -lt 8 ]] && c_warn "Terlalu pendek, coba lagi."
        done
    fi
else
    [[ -n "$ADMIN_EMAIL" ]]      || die "--admin-email wajib diisi dengan --yes"
    [[ ${#ADMIN_PASSWORD} -ge 8 ]] || die "--admin-password minimal 8 karakter"
fi

# ── 4. Buat .env (sekali, tidak ditimpa saat upgrade) ────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    c_warn ".env sudah ada — dipertahankan (hapus dulu jika ingin instalasi bersih)"
else
    c_info "Membangkitkan konfigurasi..."
    SECRET_KEY="$(openssl rand -hex 32)"
    ENCRYPTION_KEY="$(openssl rand 32 | base64 | tr -d '\n' | tr '+/' '-_')"
    POSTGRES_PASSWORD="$(openssl rand -hex 24)"
    [[ "$SCHEME" == "https" ]] && COOKIE_SECURE="true" CADDY_TLS="tls internal" \
                               || COOKIE_SECURE="false" CADDY_TLS=""

    umask 077
    cat > "$ENV_FILE" <<EOF
# Dibuat oleh install.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ)
DEPLOYMENT_MODE=$MODE
ENVIRONMENT=production
LOG_LEVEL=INFO

SITE_ADDRESS=$SITE_ADDRESS
PUBLIC_URL=$SITE_ADDRESS
CORS_ORIGINS=$SITE_ADDRESS
NEXT_PUBLIC_WS_URL=$WS_URL
HTTP_PORT=80
HTTPS_PORT=443
CADDY_TLS=$CADDY_TLS

POSTGRES_USER=scada
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=scada

SECRET_KEY=$SECRET_KEY
ENCRYPTION_KEY=$ENCRYPTION_KEY
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=30
COOKIE_SECURE=$COOKIE_SECURE
COOKIE_DOMAIN=

# Edge agent — isi setelah buat agen di UI, lalu jalankan: make prod-restart
AGENT_ENROLLMENT_CODE=
AGENT_LOG_LEVEL=INFO

LICENSE_FILE=/srv/license/license.key
IMAGE_TAG=$IMAGE_TAG
EOF
    c_ok ".env dibuat"
fi

mkdir -p "$ROOT/license" "$ROOT/backups"
touch "$ROOT/license/.gitkeep"

# ── 5. Tarik image dari ghcr.io ───────────────────────────────────────────────
echo
c_info "Mengunduh image SCADA ($IMAGE_TAG)..."
"${COMPOSE[@]}" pull
c_ok "Image siap"

# ── 6. Migrasi & bootstrap ────────────────────────────────────────────────────
c_info "Menyalakan database..."
"${COMPOSE[@]}" up -d --wait db redis

c_info "Migrasi database..."
"${COMPOSE[@]}" run --rm api alembic upgrade head

c_info "Mengisi data awal..."
"${COMPOSE[@]}" run --rm api python -m app.db.seed

c_info "Membuat akun admin..."
"${COMPOSE[@]}" run --rm \
    -e "BOOTSTRAP_ORG_NAME=$ORG_NAME" \
    -e "BOOTSTRAP_ADMIN_NAME=$ADMIN_NAME" \
    -e "BOOTSTRAP_ADMIN_EMAIL=$ADMIN_EMAIL" \
    -e "BOOTSTRAP_ADMIN_PASSWORD=$ADMIN_PASSWORD" \
    api python -m app.db.bootstrap

c_info "Menyalakan semua layanan..."
"${COMPOSE[@]}" up -d

# ── 7. Selesai ────────────────────────────────────────────────────────────────
echo
printf '\033[32m%s\033[0m\n' "╔══════════════════════════════════════╗"
printf '\033[32m%s\033[0m\n' "║  ✔  SCADA berhasil dipasang!         ║"
printf '\033[32m%s\033[0m\n' "╚══════════════════════════════════════╝"
echo
echo "  Buka browser  →  $SITE_ADDRESS"
echo "  Login email   →  $ADMIN_EMAIL"
echo
cat <<EOF
  Langkah selanjutnya — daftarkan edge agent:
    1. Buka UI → Agen → Buat Agen Baru → salin kode (enr_xxxx)
    2. Jalankan:  make agent-enroll code=enr_xxxx

  Perintah berguna:
    make prod-logs       — lihat log
    make prod-restart    — restart setelah ubah .env
    make prod-pull       — upgrade ke versi terbaru
    make backup          — cadangkan database
EOF
