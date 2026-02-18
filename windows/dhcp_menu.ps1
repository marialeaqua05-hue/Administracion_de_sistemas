<#
.SYNOPSIS
    Menú Principal DHCP
#>

# --- PRE-REQUISITOS ---
$ErrorActionPreference = "Stop"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "[!] Ejecuta este script como ADMINISTRADOR."
    Break
}

# --- VARIABLES DE ENTORNO ---
$Global:InterfaceAlias = "Ethernet"
$ScriptDir = $PSScriptRoot
$LibFile   = Join-Path $ScriptDir "dns_main.ps1"

# --- HERRAMIENTAS DE UI ---
function Show-Header ($Title) {
    Clear-Host
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host "   $Title" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Pause-Key {
    Write-Host ""
    Write-Host "Presiona cualquier tecla para continuar..." -ForegroundColor DarkGray -NoNewline
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- FUNCIONES DEL SISTEMA ---

function Menu-DNS-Laucher {
    if (Test-Path $LibFile) {
        & $LibFile # Invoca el script hijo
    } else {
        Write-Error "Falta el archivo: $LibFile"
        Pause-Key
    }
}

function Install-DHCP-Role {
    Show-Header "INSTALACION DE ROL DHCP"
    
    if (Get-WindowsFeature DHCP | Where-Object Installed) {
        Write-Host "[INFO] El rol DHCP ya esta instalado." -ForegroundColor Yellow
    } else {
        Write-Host "[...] Instalando DHCP y Herramientas..." -ForegroundColor Cyan
        Install-WindowsFeature DHCP -IncludeManagementTools
        
        Write-Host "[...] Autorizando grupo de seguridad..." -ForegroundColor Cyan
        Add-DhcpServerSecurityGroup
        Restart-Service dhcpserver
        
        Write-Host "[OK] Instalacion completada." -ForegroundColor Green
    }
    Pause-Key
}

function Configure-Network-DHCP {
    Show-Header "CONFIGURACION DE RED Y SCOPE"

    # 1. Selección de Tarjeta de Red
    Write-Host "Interfaces Disponibles:" -ForegroundColor Yellow
    Get-NetAdapter | Select-Object Name, InterfaceDescription, IPAddress | Format-Table -AutoSize
    
    $inputInt = Read-Host "Nombre de Interfaz (Enter para '$Global:InterfaceAlias')"
    if (-not [string]::IsNullOrWhiteSpace($inputInt)) { $Global:InterfaceAlias = $inputInt }

    # 2. Recolección de Datos
    $ScopeName = Read-Host "Nombre del Scope"
    
    # Validación de IP
    do {
        $ServerIP = Read-Host "IP del Servidor (Inicio de Rango)"
        $validIP = $ServerIP -as [System.Net.IPAddress]
    } until ($validIP)

    # Cálculos automáticos
    $ipBytes = $ServerIP.Split(".")
    $RangeStart = "$($ipBytes[0]).$($ipBytes[1]).$($ipBytes[2]).$([int]$ipBytes[3] + 1)"
    
    if     ([int]$ipBytes[0] -lt 128) { $Mask = "255.0.0.0";     $Cidr = 8 }
    elseif ([int]$ipBytes[0] -lt 192) { $Mask = "255.255.0.0";   $Cidr = 16 }
    else                              { $Mask = "255.255.255.0"; $Cidr = 24 }

    Write-Host "`n--- Configuracion Calculada ---" -ForegroundColor Gray
    Write-Host "   Server IP : $ServerIP"
    Write-Host "   Mascara   : $Mask (/$Cidr)"
    Write-Host "   Rango Ini : $RangeStart"

    # Datos adicionales
    do {
        $RangeEnd = Read-Host "Rango Final"
        $validEnd = $RangeEnd -as [System.Net.IPAddress]
    } until ($validEnd)

    $LeaseTime = Read-Host "Tiempo Lease (segundos)"
    $Gateway   = Read-Host "Gateway (Opcional - Enter para omitir)"
    $DNS       = Read-Host "DNS (Opcional - Enter para omitir)"

    # 3. Aplicar Configuración de Red
    Write-Host "`n[...] Configurando IP Estatica..." -ForegroundColor Cyan
    try {
        Remove-NetIPAddress -InterfaceAlias $Global:InterfaceAlias -Confirm:$false -ErrorAction SilentlyContinue
        
        $netParams = @{
            InterfaceAlias = $Global:InterfaceAlias
            IPAddress      = $ServerIP
            PrefixLength   = $Cidr
            ErrorAction    = "Stop"
        }
        if (-not [string]::IsNullOrWhiteSpace($Gateway)) { $netParams["DefaultGateway"] = $Gateway }
        
        New-NetIPAddress @netParams | Out-Null
        
        if (-not [string]::IsNullOrWhiteSpace($DNS)) {
            Set-DnsClientServerAddress -InterfaceAlias $Global:InterfaceAlias -ServerAddresses $DNS
        }
        Write-Host "[OK] Red Configurada." -ForegroundColor Green
    } catch {
        Write-Error "Fallo en red: $_"
        Pause-Key; return
    }

    # 4. Configurar Servicio DHCP
    Write-Host "[...] Creando Scope DHCP..." -ForegroundColor Cyan
    try {
        Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Remove-DhcpServerv4Scope -Force -Confirm:$false

        $scopeParams = @{
            Name          = $ScopeName
            StartRange    = $RangeStart
            EndRange      = $RangeEnd
            SubnetMask    = $Mask
            LeaseDuration = (New-TimeSpan -Seconds $LeaseTime)
            State         = "Active"
        }
        Add-DhcpServerv4Scope @scopeParams

        if ($Gateway) { Set-DhcpServerv4OptionValue -OptionId 3 -Value $Gateway }
        
        if ($DNS) {
            try {
                Set-DhcpServerv4OptionValue -OptionId 6 -Value $DNS -ErrorAction Stop
            } catch {
                Write-Warning "DNS no validado. Forzando con NETSH..."
                $scopeID = (Get-DhcpServerv4Scope | Where-Object Name -eq $ScopeName).ScopeId.IPAddressToString
                netsh dhcp server scope $scopeID set optionvalue 6 IPADDRESS $DNS | Out-Null
            }
        }

        Restart-Service dhcpserver
        Write-Host "[OK] Servicio DHCP Activo y Configurado." -ForegroundColor Green
    } catch {
        Write-Error "Fallo en DHCP: $_"
    }
    Pause-Key
}

function Monitor-Services {
    Show-Header "MONITOREO DE SERVICIOS"
    Get-Service dhcpserver | Select-Object Name, Status, StartType | Format-Table
    
    Write-Host "--- Leases Activos ---" -ForegroundColor Yellow
    Get-DhcpServerv4Lease -ScopeId (Get-DhcpServerv4Scope).ScopeId -ErrorAction SilentlyContinue | Format-Table
    Pause-Key
}

# --- BUCLE PRINCIPAL ---
do {
    Show-Header "MENU PRINCIPAL: WINDOWS SERVER DHCP"
    Write-Host "1. Instalar Rol DHCP"
    Write-Host "2. Verificar Instalacion"
    Write-Host "3. Configurar Red y Scope"
    Write-Host "4. Monitorear Servicio"
    Write-Host "5. IR AL MENU DNS >>"
    Write-Host "6. Salir"
    Write-Host ""
    
    $Choice = Read-Host " Seleccione una opcion"
    
    switch ($Choice) {
        '1' { Install-DHCP-Role }
        '2' { Show-Header "ESTADO"; Get-WindowsFeature DHCP; Pause-Key }
        '3' { Configure-Network-DHCP }
        '4' { Monitor-Services }
        '5' { Menu-DNS-Laucher }
        '6' { Write-Host "Adios!"; exit }
        default { Write-Warning "Opcion invalida." ; Start-Sleep -Seconds 1 }
    }
} until ($false)