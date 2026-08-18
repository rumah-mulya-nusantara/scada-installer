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
