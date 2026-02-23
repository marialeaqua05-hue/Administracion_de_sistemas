<#
.SYNOPSIS
    Panel Central de Administracion de Servidor
#>

$ErrorActionPreference = "Stop"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Se requiere ejecutar PowerShell como Administrador."
    Break
}

# --- IMPORTAR MÓDULOS ---
$ScriptDir = $PSScriptRoot
$DHCP_Lib = Join-Path $ScriptDir "dhcp_funciones.ps1"
$DNS_Lib  = Join-Path $ScriptDir "dns_lib.ps1"
$SSH_Lib  = Join-Path $ScriptDir "ssh_funciones.ps1"

if (Test-Path $DHCP_Lib) { . $DHCP_Lib } else { Write-Host "Falta: dhcp_funciones.ps1" }
if (Test-Path $DNS_Lib)  { . $DNS_Lib  } else { Write-Host "Falta: dns_lib.ps1" }
if (Test-Path $SSH_Lib)  { . $SSH_Lib  } else { Write-Host "Falta: ssh_lib.ps1" }

Start-Sleep -Seconds 1

# --- BUCLE PRINCIPAL ---
do {
    Clear-Host
    Write-Host "=========================================="
    Write-Host "     PANEL DE CONTROL DEL SERVIDOR"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host " [ 1 ] Gestion de Red (DHCP)"
    Write-Host " [ 2 ] Resolucion de Nombres (DNS)"
    Write-Host " [ 3 ] Acceso Remoto (SSH)"
    Write-Host " [ 0 ] Salir del Sistema"
    Write-Host ""
    
    $Selection = Read-Host "Seleccione un modulo"
    
    switch ($Selection.Trim()) {
        '1' { 
            if (Get-Command menu_dhcp -ErrorAction SilentlyContinue) { menu_dhcp } 
            else { Write-Host "Modulo DHCP no disponible."; Start-Sleep -Seconds 1 } 
        }
        '2' { 
            if (Get-Command dns_menu -ErrorAction SilentlyContinue) { dns_menu } 
            else { Write-Host "Modulo DNS no disponible."; Start-Sleep -Seconds 1 } 
        }
        '3' { 
            if (Get-Command ssh_menu -ErrorAction SilentlyContinue) { ssh_menu } 
            else { Write-Host "Modulo SSH no disponible."; Start-Sleep -Seconds 1 } 
        }
        '0' { Write-Host "`nCerrando panel..."; exit }
        default { Write-Host "Comando no reconocido." ; Start-Sleep -Seconds 1 }
    }
} until ($false)