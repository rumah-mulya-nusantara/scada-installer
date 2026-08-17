#!/usr/bin/env bash
# get.sh — Bootstrap installer SCADA.
#
# Cara pakai (satu perintah di server):
#
#   curl -fsSL https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-ruanglab/main/get.sh | bash
#
# Atau dengan opsi langsung:
#
#   curl -fsSL .../get.sh | bash -s -- --http --admin-email a@b.com --admin-password 'Rahasia123'
#
set -euo pipefail

REPO="rumah-mulya-nusantara/scada-installer"
BRANCH="main"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
INSTALL_DIR="${SCADA_DIR:-/opt/scada}"


c_ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m·\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✘\033[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

# ── Prasyarat ─────────────────────────────────────────────────────────────────
command -v docker > /dev/null 2>&1 || die "Docker belum terpasang. Lihat: https://docs.docker.com/engine/install/"
docker compose version > /dev/null 2>&1 || die "Plugin 'docker compose' v2 tidak tersedia."
docker info > /dev/null 2>&1 || die "Docker daemon tidak berjalan."
command -v curl > /dev/null 2>&1 || die "curl tidak tersedia."
command -v openssl > /dev/null 2>&1 || die "openssl tidak tersedia."

echo
c_info "SCADA — Installer bootstrap"
c_info "Direktori instalasi: $INSTALL_DIR"
echo

# ── Buat direktori & unduh file ───────────────────────────────────────────────
mkdir -p "$INSTALL_DIR/infra/caddy"
cd "$INSTALL_DIR"

c_info "Mengunduh file instalasi..."
curl -fsSL "$RAW/docker-compose.prod.yml" -o docker-compose.prod.yml
curl -fsSL "$RAW/install.sh"              -o install.sh
curl -fsSL "$RAW/Makefile"                -o Makefile
curl -fsSL "$RAW/infra/caddy/Caddyfile"  -o infra/caddy/Caddyfile
chmod +x install.sh
c_ok "File berhasil diunduh ke $INSTALL_DIR"

# ── Jalankan installer dengan argumen yang diteruskan ─────────────────────────
echo
exec bash install.sh --http "$@"
