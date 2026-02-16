<#
.SYNOPSIS
    Gestor DHCP Automatizado para Windows Server 2022 Core
    Versión: CORREGIDA Y VERIFICADA
#>

$ErrorActionPreference = "Stop"

# --- FUNCIONES AUXILIARES ---

function Show-Header {
    param([string]$Title)
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "      $Title" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Pause-Script {
    Write-Host ""
    Read-Host "Presione Enter para continuar..."
}

function Calc-Mask {
    param([string]$IP)
    $firstOctet = [int]($IP.Split('.')[0])
    if ($firstOctet -lt 128) { return "255.0.0.0" }      # Clase A
    if ($firstOctet -lt 192) { return "255.255.0.0" }    # Clase B
    return "255.255.255.0"                               # Clase C
}

function Calc-IPPlusOne {
    param([string]$IP)
    try {
        $parts = $IP.Split('.')
        $last = [int]$parts[3] + 1
        if ($last -gt 254) { throw "Desbordamiento de octeto" }
        return "$($parts[0]).$($parts[1]).$($parts[2]).$last"
    } catch {
        return $null
    }
}

function Validate-IP {
    param([string]$IP, [bool]$AllowEmpty = $false)
    
    # Limpiamos espacios por seguridad
    $IP = $IP.Trim()

    if ([string]::IsNullOrWhiteSpace($IP)) { return $AllowEmpty }
    
    # Validaciones prohibidas explícitas
    if ($IP -in @("0.0.0.0", "127.0.0.1", "255.255.255.255")) { 
        Write-Host "IP $IP no es válida (Reservada)." -ForegroundColor Red
        return $false 
    }

    if ($IP -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        $parts = $IP.Split('.')
        foreach ($p in $parts) { if ([int]$p -lt 0 -or [int]$p -gt 255) { return $false } }
        return $true
    }
    return $false
}

# --- MÓDULOS PRINCIPALES ---

function Module-Install {
    Show-Header "INSTALACIÓN / REINSTALACIÓN DHCP"
    
    $check = Get-WindowsFeature -Name DHCP
    if ($check.Installed) {
        Write-Host "El rol DHCP ya está instalado." -ForegroundColor Yellow
        $resp = Read-Host "¿Desea REINSTALAR (Borrar configuración y reinstalar)? (S/N)"
        if ($resp.Trim().ToUpper() -eq 'S') {
            Write-Host "Desinstalando..." -ForegroundColor Red
            Uninstall-WindowsFeature -Name DHCP -Remove -IncludeManagementTools
            Write-Host "Reinstalando..." -ForegroundColor Green
            Install-WindowsFeature -Name DHCP -IncludeManagementTools
        } else {
            return
        }
    } else {
        Write-Host "Instalando Rol DHCP..." -ForegroundColor Green
        Install-WindowsFeature -Name DHCP -IncludeManagementTools
    }
    
    Write-Host "Configurando grupos de seguridad..."
    Add-DhcpServerSecurityGroup
    Restart-Service dhcpserver
    Write-Host "Proceso completado." -ForegroundColor Green
    Pause-Script
}

function Module-Verify {
    Show-Header "VERIFICAR INSTALACIÓN"
    $check = Get-WindowsFeature -Name DHCP
    if ($check.Installed) {
        Write-Host "Estado: INSTALADO" -ForegroundColor Green
        Write-Host "Exit Code: $($check.InstallState)"
    } else {
        Write-Host "Estado: NO INSTALADO" -ForegroundColor Red
    }
    Pause-Script
}

function Module-Config {
    Show-Header "CONFIGURACIÓN DHCP"
    
    # Selección de Interfaz
    $adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
    $adapters | Select-Object Name, InterfaceDescription, IPAddress | Format-Table -AutoSize
    $iface = Read-Host "Nombre de la interfaz a configurar (ej. Ethernet 2)"
    $iface = $iface.Trim()
    
    if (-not (Get-NetAdapter -Name $iface -ErrorAction SilentlyContinue)) {
        Write-Host "Interfaz no encontrada." -ForegroundColor Red; Pause-Script; return
    }

    # Entradas de Usuario
    $scopeName = Read-Host "Nombre del Ámbito (Scope)"
    
    do { 
        $ipInput = Read-Host "IP Inicio (Se usará como IP Servidor)" 
        $ipInput = $ipInput.Trim()
    } while (-not (Validate-IP $ipInput))

    # Lógica: IP Servidor = IP Input | DHCP Start = IP Input + 1
    $serverIP = $ipInput
    $dhcpStart = Calc-IPPlusOne $ipInput
    $mask = Calc-Mask $serverIP
    
    Write-Host "-> IP Servidor asignada: $serverIP" -ForegroundColor Gray
    Write-Host "-> Rango DHCP inicia en: $dhcpStart" -ForegroundColor Gray
    Write-Host "-> Máscara calculada:    $mask" -ForegroundColor Gray

    do {
        $dhcpEnd = Read-Host "IP Final del Rango (Mayor a $dhcpStart)"
        $dhcpEnd = $dhcpEnd.Trim()
        $valid = (Validate-IP $dhcpEnd) -and ([version]$dhcpEnd -ge [version]$dhcpStart)
        if (-not $valid) { Write-Host "IP inválida o menor al inicio." -ForegroundColor Red }
    } while (-not $valid)

    do {
        $leaseSecs = Read-Host "Tiempo de concesión (segundos)"
    } while ($leaseSecs -notmatch "^\d+$")

    do { 
        $gateway = Read-Host "Gateway (Enter para vacío)" 
        $gateway = $gateway.Trim()
    } while (-not (Validate-IP $gateway $true))
    
    do { 
        $dns = Read-Host "DNS (Enter para vacío)" 
        $dns = $dns.Trim() # <--- El .Trim() soluciona espacios accidentales
    } while (-not (Validate-IP $dns $true))

    # Aplicar Configuración
    try {
        Write-Host "[1/3] Configurando IP Estática en $iface..." -ForegroundColor Cyan
        
        $cidr = switch ($mask) { "255.0.0.0" {8} "255.255.0.0" {16} "255.255.255.0" {24} Default {24} }
        
        Remove-NetIPAddress -InterfaceAlias $iface -Confirm:$false -ErrorAction SilentlyContinue
        
        $ipParams = @{
            InterfaceAlias = $iface
            IPAddress      = $serverIP
            PrefixLength   = $cidr
            ErrorAction    = "Stop"
        }
        
        if (-not [string]::IsNullOrWhiteSpace($gateway)) {
            $ipParams.Add("DefaultGateway", $gateway)
        }

        New-NetIPAddress @ipParams
        
        Write-Host "[2/3] Configurando Servicio DHCP..." -ForegroundColor Cyan
        Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Remove-DhcpServerv4Scope -Force

        $leaseDuration = New-TimeSpan -Seconds $leaseSecs
        Add-DhcpServerv4Scope -Name $scopeName -StartRange $dhcpStart -EndRange $dhcpEnd -SubnetMask $mask -LeaseDuration $leaseDuration -State Active

        Write-Host "[3/3] Configurando Opciones DHCP..." -ForegroundColor Cyan
        if ($gateway) { Set-DhcpServerv4OptionValue -OptionId 3 -Value $gateway }
        if ($dns) { Set-DhcpServerv4OptionValue -OptionId 6 -Value $dns }

        Restart-Service dhcpserver
        Write-Host "¡Configuración Exitosa!" -ForegroundColor Green
    } catch {
        Write-Host "ERROR CRÍTICO: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause-Script
}

function Module-Monitor {
    Show-Header "MONITOREO Y ESTADO"
    
    Write-Host "[SERVICIO]" -ForegroundColor Yellow
    Get-Service dhcpserver | Select-Object Status, StartType, Name | Format-Table -AutoSize

    Write-Host "[ÁMBITOS]" -ForegroundColor Yellow
    Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State, StartRange, EndRange | Format-Table -AutoSize

    Write-Host "[CONCESIONES ACTIVAS (CLIENTES)]" -ForegroundColor Yellow
    try {
        $scope = Get-DhcpServerv4Scope -ErrorAction Stop
        $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId
        if ($leases) {
            $leases | Select-Object IPAddress, HostName, ClientId, LeaseExpiryTime | Format-Table -AutoSize
        } else {
            Write-Host "No hay clientes conectados." -ForegroundColor Gray
        }
    } catch {
        Write-Host "No se pudo obtener información de leases (¿Quizás no hay scope?)." -ForegroundColor DarkGray
    }
    Pause-Script
}

# --- MENÚ PRINCIPAL ---

do {
    Show-Header "MENÚ PRINCIPAL DHCP (WINDOWS SERVER)"
    Write-Host "1. Instalación DHCP (Idempotente)"
    Write-Host "2. Verificar Instalación"
    Write-Host "3. Configuración de DHCP"
    Write-Host "4. Monitorear (Estado y Leases)"
    Write-Host "5. Salir"
    
    $op = Read-Host "Seleccione una opción"
    switch ($op) {
        '1' { Module-Install }
        '2' { Module-Verify }
        '3' { Module-Config }
        '4' { Module-Monitor }
        '5' { Write-Host "Saliendo..."; Start-Sleep 1 }
        Default { Write-Host "Opción inválida" -ForegroundColor Red; Start-Sleep 1 }
    }
} until ($op -eq '5')