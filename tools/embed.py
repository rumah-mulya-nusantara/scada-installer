#!/usr/bin/env python3
"""Menjaga docker-compose.prod.yml dan Caddyfile tetap satu sumber.

Kedua installer menanam isi berkas ini agar pemasangan cukup satu unduhan;
berkas kanonik di repo tetap yang diedit manusia.

    tools/embed.py sync    tanam ulang berkas kanonik ke install.sh & install.ps1
    tools/embed.py check   gagal bila salinan tertanam sudah menyimpang
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

BLOCKS = [
    ("docker-compose.prod.yml", "install.sh",
     "cat > docker-compose.prod.yml <<'YAML'\n", "YAML\n"),
    ("infra/caddy/Caddyfile", "install.sh",
     "cat > infra/caddy/Caddyfile <<'CADDY'\n", "CADDY\n"),
    ("tools/reset_password.py", "install.sh",
     "cat > reset_password.py <<'PYFILE'\n", "PYFILE\n"),
    ("docker-compose.prod.yml", "install.ps1",
     "$ComposeYaml = @'\n", "'@\n"),
    ("tools/reset_password.py", "install.ps1",
     "$ResetPasswordPy = @'\n", "'@\n"),
    ("infra/caddy/Caddyfile", "install.ps1",
     "$Caddyfile = @'\n", "'@\n"),
]


def split(text: str, start: str, end: str, where: str) -> tuple[str, str, str]:
    i = text.find(start)
    if i < 0:
        sys.exit(f"penanda awal tidak ditemukan di {where}: {start!r}")
    i += len(start)
    j = text.find(end, i)
    if j < 0:
        sys.exit(f"penanda akhir tidak ditemukan di {where}: {end!r}")
    return text[:i], text[i:j], text[j:]


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    if mode not in ("sync", "check"):
        sys.exit(__doc__)

    drift = False
    pending: dict[str, str] = {}

    for canon, target, start, end in BLOCKS:
        want = (ROOT / canon).read_text()
        text = pending.get(target) or (ROOT / target).read_text()
        head, body, tail = split(text, start, end, target)

        if body == want:
            print(f"  ok     {target}  ←  {canon}")
        elif mode == "sync":
            pending[target] = head + want + tail
            print(f"  sync   {target}  ←  {canon}")
        else:
            print(f"  DRIFT  {target}  ←  {canon}")
            drift = True

    for target, text in pending.items():
        (ROOT / target).write_text(text)

    if drift:
        print("\nSalinan tertanam sudah menyimpang. Jalankan: tools/embed.py sync")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
