@echo off
REM ============================================================================
REM  SCADA - pemasang Windows, tinggal klik dua kali.
REM
REM  Berkas ini sengaja BUKAN .exe. PS2EXE menanamkan skrip PowerShell di dalam
REM  executable .NET - teknik yang sama dengan yang dipakai malware - jadi
REM  hasilnya rutin ditandai Windows Defender. Dan setiap .exe yang diunduh
REM  tanpa sertifikat code-signing memunculkan layar "Windows protected your PC".
REM  Dua peringatan menakutkan itu lebih menyulitkan pelanggan daripada berkas
REM  .cmd biasa, yang tidak memicu SmartScreen dan tidak perlu ditandatangani.
REM
REM  Kalau suatu hari sertifikat EV code-signing dibeli, barulah .exe masuk akal:
REM  bungkus dengan PS2EXE, tandatangani dengan signtool, lalu uji unduh dari
REM  mesin bersih untuk memastikan SmartScreen benar-benar diam.
REM ============================================================================

setlocal
set "SCADA_INSTALL_URL=https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.ps1"

echo.
echo   Pemasang SCADA untuk Windows
echo   ----------------------------
echo.
echo   Yang akan terjadi:
echo     - Docker Desktop dipasang bila belum ada ^(minta izin UAC^)
echo     - Anda ditanya email dan kata sandi admin
echo     - SCADA dipasang di %USERPROFILE%\scada
echo.
echo   Butuh koneksi internet. Tekan Ctrl+C untuk membatalkan.
echo.
pause

REM -ExecutionPolicy Bypass hanya berlaku untuk proses ini, tidak mengubah
REM setelan mesin. Tanpa itu, kebijakan bawaan Windows menolak menjalankan
REM skrip yang diunduh, dan pelanggan melihat galat yang tidak bisa ia tafsirkan.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { irm '%SCADA_INSTALL_URL%' | iex } catch { Write-Host ''; Write-Host ('  GAGAL: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }"

set "KODE=%ERRORLEVEL%"
echo.
if not "%KODE%"=="0" (
    echo   Pemasangan berhenti dengan kode %KODE%.
    echo   Salin pesan di atas saat menghubungi vendor.
) else (
    echo   Selesai. Jendela ini boleh ditutup.
)
echo.
REM pause di akhir supaya jendela tidak tertutup sendiri saat diklik dua kali -
REM tanpa ini pesan galat apa pun hilang sebelum sempat dibaca.
pause
endlocal
