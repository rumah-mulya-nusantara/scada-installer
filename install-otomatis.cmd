@echo off
REM ============================================================================
REM  SCADA - pemasangan tanpa tanya-jawab.
REM
REM  Untuk memasang banyak mesin sekaligus atau lewat alat manajemen jarak jauh.
REM  Email dan kata sandi admin WAJIB diisi di bawah sebelum dijalankan.
REM
REM  PERINGATAN: berkas ini memuat kata sandi admin dalam teks biasa. Jangan
REM  simpan di berbagi jaringan, jangan kirim lewat surel, dan hapus setelah
REM  pemasangan selesai. Untuk satu-dua mesin, pakai install.cmd yang menanyakan
REM  kata sandinya secara interaktif.
REM ============================================================================

setlocal
set "SCADA_INSTALL_URL=https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.ps1"

REM ---- ISI TIGA BARIS INI ----------------------------------------------------
set "SCADA_ADMIN_EMAIL=admin@pabrik.co.id"
set "SCADA_ADMIN_PASSWORD="
set "SCADA_ORG=Nama Perusahaan"

REM Opsional. Kosongkan kalau tidak dipakai.
set "SCADA_LICENSE_PORTAL_URL="
REM ----------------------------------------------------------------------------

set "SCADA_YES=1"

if "%SCADA_ADMIN_PASSWORD%"=="" (
    echo.
    echo   SCADA_ADMIN_PASSWORD masih kosong.
    echo   Buka berkas ini dengan Notepad dan isi dulu, lalu jalankan lagi.
    echo.
    pause
    exit /b 1
)

echo.
echo   Memasang SCADA tanpa tanya-jawab untuk %SCADA_ORG%...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { irm '%SCADA_INSTALL_URL%' | iex } catch { Write-Host ''; Write-Host ('  GAGAL: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }"

set "KODE=%ERRORLEVEL%"
echo.
if not "%KODE%"=="0" (
    echo   Pemasangan berhenti dengan kode %KODE%.
) else (
    echo   Selesai. Hapus berkas ini sekarang - ia memuat kata sandi admin.
)
echo.
pause
endlocal
