# SCADA — Installer

Pemasang **SCADA HMI Builder & Universal Gateway** untuk server on-premise.
Satu perintah, satu berkas, tanpa perlu source code di mesin tujuan.

## Pasang

**Linux · macOS · WSL · Git Bash**

```bash
curl -fsSL https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.sh | bash
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.ps1 | iex
```

Installer akan, dalam satu jalan:

1. memasang Docker bila belum ada (`get.docker.com`, Homebrew, atau winget) dan menunggunya siap;
2. memilih direktori instalasi — `/opt/scada` di Linux, `~/scada` di macOS/Windows, karena Docker
   Desktop hanya membagikan `$HOME` secara bawaan;
3. mendeteksi alamat IP server dan port HTTP yang bebas (mundur ke 8080 bila 80 terpakai);
4. menanyakan email dan kata sandi admin;
5. membangkitkan `.env` berisi rahasia acak, lalu menulis `docker-compose.prod.yml` dan `Caddyfile`;
6. menarik image dari ghcr.io, menjalankan migrasi, mengisi data awal, membuat akun admin;
7. memasang perintah `scada` supaya operator tidak perlu menghafal `docker compose`, lalu
   menjadwalkan pembaruan otomatis harian.

Menjalankan ulang perintah yang sama di mesin yang sudah terpasang adalah **upgrade**: `.env` dan
akun admin dipertahankan, image ditarik ulang, migrasi dijalankan lagi.

## Tanpa interaksi

```bash
curl -fsSL .../install.sh | bash -s -- --yes \
  --admin-email admin@pabrik.co.id --admin-password 'Rahasia123'
```

```powershell
$env:SCADA_ADMIN_EMAIL = 'admin@pabrik.co.id'
$env:SCADA_ADMIN_PASSWORD = 'Rahasia123'
$env:SCADA_YES = '1'
irm .../install.ps1 | iex
```

`iex` tidak bisa menerima parameter, jadi di Windows semua opsi lewat environment:
`SCADA_DIR`, `SCADA_HOST`, `SCADA_PORT`, `SCADA_ORG`, `SCADA_ADMIN_NAME`, `SCADA_ADMIN_EMAIL`,
`SCADA_ADMIN_PASSWORD`, `SCADA_TAG`, `SCADA_AUTO_UPDATE`, `SCADA_UPDATE_AT`, `SCADA_YES`. Di Linux/macOS opsi yang sama tersedia sebagai
flag (`install.sh --help`) maupun environment.

## Mengelola

```
scada start | stop | restart | status
scada logs [layanan]      ikuti log (api, web, worker, agent, db)
scada open | url          buka antarmuka
scada update              pasang versi terbaru sekarang
scada update --check      lihat apakah ada versi baru
scada autoupdate on|off   pembaruan otomatis harian
scada autoupdate          status dan jadwalnya
scada doctor              periksa kenapa tidak bisa dipakai
scada create-admin <email> <sandi>    buat admin pertama
scada reset-password <email> <sandi>  ganti kata sandi
scada enroll enr_xxxx     daftarkan edge agent
scada backup              cadangkan database + .env
scada restore <berkas>    pulihkan dari cadangan
scada uninstall           hapus kontainer dan volume
```

## Tidak bisa login

```bash
scada doctor
```

Menampilkan status kontainer, apakah `/health` menjawab, jumlah organisasi dan pengguna, daftar
email admin beserta statusnya, lalu galat terakhir di log api. Kalau tabel penggunanya masih kosong
ia akan mengatakannya langsung — itu penyebab paling sering login ditolak setelah instalasi yang
sempat gagal di tengah jalan.

```bash
scada create-admin admin@pabrik.co.id 'KataSandiMin8'    # belum ada admin sama sekali
scada reset-password admin@pabrik.co.id 'SandiBaru123'   # lupa kata sandi
```

`reset-password` memakai fungsi hash yang sama dengan alur login (argon2), mengaktifkan kembali akun
yang berstatus `invited` atau `suspended` — keduanya ditolak saat login — dan **mencabut seluruh
sesi lama**, sehingga perangkat yang masih memegang refresh token ikut terputus. Kata sandi dikirim
lewat environment, bukan argumen, jadi tidak muncul di daftar proses.

## Pembaruan otomatis

Setiap instalasi mengikuti tag `latest` di ghcr.io. Sekali sehari — bawaannya sekitar pukul 02:30,
dengan sebaran acak sampai 30 menit supaya semua pelanggan tidak menarik image serentak — mesin
memeriksa apakah ada image baru. Bila tidak ada, tidak terjadi apa-apa dan tidak ada layanan yang
disentuh. Bila ada:

1. **cadangkan database** (`pg_dump -Fc` + salinan `.env`) — ini jalan pulang bila migrasi
   ternyata bermasalah;
2. jalankan `alembic upgrade head` memakai image baru;
3. baru recreate kontainer, lalu tunggu `/health` hijau.

Urutan itu disengaja: kalau migrasi gagal, kontainer lama **masih berjalan** dan pabrik tidak
berhenti. Kalau layanan tidak sehat sesudah recreate, jam berapa pun itu terjadi, catatannya masuk
ke `update.log` lengkap dengan nama berkas cadangan untuk `scada restore`.

Sidik jari image yang terakhir berhasil dipasang disimpan di `.update-state`. Perbandingan dilakukan
terhadap berkas itu, bukan terhadap keadaan sebelum `pull` — sehingga pembaruan yang gagal di tengah
jalan akan dicoba lagi malam berikutnya, bukan dilewati diam-diam.

Penjadwalnya systemd timer bila ada, kalau tidak cron; di Windows Task Scheduler.

```bash
scada autoupdate          # status, jadwal, dan catatan terakhir
scada autoupdate off      # matikan
scada update --check      # periksa manual, tanpa memasang
```

**Instalasi air-gapped harus mematikannya** — pemeriksaan harian itu satu-satunya panggilan keluar
yang tersisa di stack ini. Pasang dengan `--auto-update off` (atau `$env:SCADA_AUTO_UPDATE = 'off'`)
sejak awal.

Untuk kendali rilis yang lebih ketat, pasang `IMAGE_TAG` di `.env` ke versi tertentu
(mis. `IMAGE_TAG=v1.4.2`) lalu `scada restart`. Pembaruan otomatis akan mengikuti tag itu dan
berhenti bergerak sampai Anda menaikkannya sendiri.

`scada backup` menyalin `.env` bersama dump-nya. Tanpa `.env` itu kredensial device di database
tidak bisa dibuka lagi — simpan keduanya.

## Edge agent

Agent ikut naik bersama stack tapi diam sampai didaftarkan:

1. buka UI → **Agen** → **Buat Agen Baru** → salin kode `enr_xxxx`
2. `scada enroll enr_xxxx`

Setelah enrolment, kuncinya tersimpan di volume `agent_state`; kodenya tidak diperlukan lagi.

## Isi repo

| Berkas | Peran |
|---|---|
| `install.sh` / `install.ps1` | pemasang berdiri sendiri — satu-satunya yang perlu diunduh |
| `docker-compose.prod.yml` | definisi stack, **sumber kanonik** |
| `infra/caddy/Caddyfile` | konfigurasi reverse proxy, **sumber kanonik** |
| `tools/reset_password.py` | dipakai `scada reset-password`, **sumber kanonik** |
| `tools/embed.py` | menanam ulang ketiga berkas kanonik itu ke dalam kedua installer |
| `get.sh` / `get.ps1` | alias lama, meneruskan ke `install.sh` / `install.ps1` |

Kedua installer memuat salinan `docker-compose.prod.yml`, `Caddyfile`, dan `reset_password.py`
di dalamnya supaya pemasangan cukup satu unduhan. Setelah menyunting berkas kanonik, jalankan:

```bash
tools/embed.py sync     # tanam ulang
tools/embed.py check    # dipakai CI; gagal bila menyimpang
```

## Prasyarat

Hanya Docker — dan itu pun dipasang otomatis. Gunakan `--no-docker-install` (atau
`-NoDockerInstall`) bila mesin tujuan mengaturnya sendiri.

Instalasi on-premise tidak melakukan panggilan keluar apa pun setelah image tertarik; alamat
`raw.githubusercontent.com` dan `ghcr.io` hanya dibutuhkan saat memasang dan saat `scada update`.
