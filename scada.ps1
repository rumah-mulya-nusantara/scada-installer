<#
.SYNOPSIS
Wrapper operasi harian SCADA untuk lingkungan Windows.

.DESCRIPTION
Menggantikan Makefile di sistem Windows agar operator bisa mengelola
container SCADA tanpa perlu menginstal Make.
#>

param (
    [Parameter(Position = 0)]
    [string]$Command = "",
    
    [Parameter(Position = 1)]
    [string]$Arg1 = ""
)

$ErrorActionPreference = "Stop"
$ROOT = (Get-Location).Path
$COMPOSE = "docker", "compose", "-f", "docker-compose.prod.yml"

function Show-Help {
    Write-Host "Manajer Layanan SCADA (Windows)`n" -ForegroundColor Cyan
    Write-Host "Penggunaan: .\scada.ps1 <perintah> [argumen]`n"
    Write-Host "Perintah:"
    Write-Host "  logs            Lihat log semua layanan"
    Write-Host "  restart         Muat ulang layanan (setelah ubah .env)"
    Write-Host "  pull            Tarik image terbaru dari ghcr.io"
    Write-Host "  ps              Lihat status kontainer"
    Write-Host "  enroll <code>   Daftarkan edge agent (contoh: .\scada.ps1 enroll enr_123)"
    Write-Host "  agent-logs      Lihat log edge agent"
    Write-Host "  agent-restart   Restart edge agent"
    Write-Host ""
}

switch ($Command) {
    "logs" {
        & docker compose -f docker-compose.prod.yml logs -f --tail=100
    }
    "restart" {
        & docker compose -f docker-compose.prod.yml up -d --force-recreate
    }
    "pull" {
        & docker compose -f docker-compose.prod.yml pull
    }
    "ps" {
        & docker compose -f docker-compose.prod.yml ps
    }
    "agent-logs" {
        & docker compose -f docker-compose.prod.yml logs -f agent
    }
    "agent-restart" {
        & docker compose -f docker-compose.prod.yml restart agent
    }
    "enroll" {
        if ([string]::IsNullOrWhiteSpace($Arg1)) {
            Write-Host "✘ Error: Sertakan enrollment code. Contoh: .\scada.ps1 enroll enr_xxxx" -ForegroundColor Red
            exit 1
        }
        
        $EnvFile = Join-Path $ROOT ".env"
        if (-not (Test-Path $EnvFile)) {
            Write-Host "✘ Error: File .env tidak ditemukan. Jalankan instalasi dulu." -ForegroundColor Red
            exit 1
        }
        
        $Content = Get-Content -Path $EnvFile -Raw
        if ($Content -match '(?m)^AGENT_ENROLLMENT_CODE=.*$') {
            $Content = $Content -replace '(?m)^AGENT_ENROLLMENT_CODE=.*$', "AGENT_ENROLLMENT_CODE=$Arg1"
        } else {
            $Content += "`nAGENT_ENROLLMENT_CODE=$Arg1"
        }
        Set-Content -Path $EnvFile -Value $Content -Encoding UTF8
        Write-Host "✔ Enrollment code disimpan ke .env" -ForegroundColor Green
        
        & docker compose -f docker-compose.prod.yml restart agent
        Write-Host "✔ Agent di-restart. Pantau log: .\scada.ps1 agent-logs" -ForegroundColor Green
    }
    default {
        Show-Help
    }
}
