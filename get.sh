#!/usr/bin/env bash
# Alias lama. Entri resminya sekarang install.sh, yang sudah berdiri sendiri.
#
#   curl -fsSL https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.sh | bash
#
set -euo pipefail
curl -fsSL "https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.sh" | bash -s -- "$@"
