<#
.SYNOPSIS
    Menú DNS - Dashboard
#>

# --- CARGAR LIBRERÍA ---
$LibPath = Join-Path $PSScriptRoot "dns_lib.ps1"

if (Test-Path $LibPath) {
    . $LibPath
} else {
    Write-Error "FATAL: No se encuentra $LibPath"
    Read-Host "Presiona Enter para salir..."
    Exit
}

# --- UI HELPER ---
function Show-DNS-Header {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "      SERVIDOR DNS AUTOMATIZADO" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host ""
}

# --- BUCLE DE MENÚ ---
do {
    Show-DNS-Header
    Write-Host "1. Instalar DNS y Configurar Localhost"
    Write-Host "2. Agregar Dominio (Zona A)"
    Write-Host "3. Eliminar Dominio"
    Write-Host "4. Listar Dominios"
    Write-Host "5. Probar Resolucion (Test)"
    Write-Host "6. Volver al Menu DHCP"
    Write-Host ""
    
    $Selection = Read-Host " Elija una opcion"
    
    switch ($Selection.Trim()) {
        '1' { Install-DNS-Feature }
        '2' { New-ZoneDomain }
        '3' { Remove-ZoneDomain }
        '4' { Get-ZoneList }
        '5' { Test-DNSResolution }
        '6' { return }
        default { 
            Write-Warning "Opcion no reconocida." 
            Start-Sleep -Seconds 1
        }
    }
} until ($false)