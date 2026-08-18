# Alias lama. Entri resminya sekarang install.ps1, yang sudah berdiri sendiri.
#
#   irm https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.ps1 | iex
#
$ErrorActionPreference = 'Stop'
Invoke-RestMethod 'https://raw.githubusercontent.com/rumah-mulya-nusantara/scada-installer/main/install.ps1' | Invoke-Expression
