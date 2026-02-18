<#
.SYNOPSIS
    Libreria DNS
#>

# Variable "Script Scope"
$Script:ServerIP = $null
$Script:Interface = $Global:InterfaceAlias

function Get-SystemIP {
    # 1. Intentamos detectar la IP estatica manual (la que configuraste en DHCP)
    # Buscamos IPs que NO sean de autoconfiguracion (169.254) ni localhost (127)
    $ipConfig = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
        $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -eq "Manual"
    } | Select-Object -First 1
    
    # 2. Si no hay manual, tomamos cualquiera valida (caso de reserva DHCP)
    if (-not $ipConfig) {
        $ipConfig = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
            $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" 
        } | Select-Object -First 1
    }
    
    if ($ipConfig) {
        $Script:ServerIP = $ipConfig.IPAddress
        # Guardamos el Alias de la interfaz que tiene la IP Servidor
        $Script:Interface = $ipConfig.InterfaceAlias
        return $true
    }
    return $false
}

function Install-DNS-Feature {
    Clear-Host
    Write-Host "--- GESTOR DE INSTALACION DNS ---" -ForegroundColor Cyan
    
    if (Get-WindowsFeature DNS | Where-Object Installed) {
        Write-Host "[INFO] El rol DNS ya esta presente." -ForegroundColor Yellow
    } else {
        Write-Host "[...] Instalando Servidor DNS..." -ForegroundColor Cyan
        Install-WindowsFeature DNS -IncludeManagementTools
        Write-Host "[OK] Instalado." -ForegroundColor Green
    }

    if (Get-SystemIP) {
        Write-Host "`n[CONFIG] Configurando Resolucion para TODAS las interfaces..." -ForegroundColor Cyan
        Write-Host "   IP del Servidor detectada: $Script:ServerIP"
        Write-Host "   Aplicando esta IP como DNS UNICO en todos los adaptadores..."
        
        # --- CORRECCION CRITICA: BARRIDO TOTAL ---
        # Obtenemos TODAS las tarjetas de red fisicas/virtuales activas
        $adapters = Get-NetAdapter | Where-Object Status -eq "Up"
        
        foreach ($nic in $adapters) {
            Write-Host "   -> Configurando adaptador: $($nic.Name)" -ForegroundColor Gray
            # Forzamos que usen TU servidor como DNS (y nada mas)
            Set-DnsClientServerAddress -InterfaceAlias $nic.Name -ServerAddresses $Script:ServerIP
        }
        
        # Limpiamos cache para olvidar al 192.168.100.1
        Clear-DnsClientCache
        # -----------------------------------------
        
        Write-Host "[OK] El servidor ahora tiene control total del DNS." -ForegroundColor Green
    } else {
        Write-Error "[ERROR] No se detecto ninguna IP valida en el servidor."
    }
    Read-Host "Presiona Enter..."
}

function New-ZoneDomain {
    Clear-Host
    Write-Host "--- AGREGAR NUEVO DOMINIO ---" -ForegroundColor Cyan
    
    if (-not (Get-SystemIP)) { Write-Error "Sin IP detectada."; Read-Host; return }

    $DomainName = Read-Host "Nombre del Dominio (ej. reprobados.com)"
    if ([string]::IsNullOrWhiteSpace($DomainName)) { return }

    if (Get-DnsServerZone -Name $DomainName -ErrorAction SilentlyContinue) {
        Write-Warning "[WARN] El dominio '$DomainName' ya existe."
        Read-Host; return
    }

    Write-Host "[...] Creando zona apuntando a $Script:ServerIP ..."
    try {
        Add-DnsServerPrimaryZone -Name $DomainName -ZoneFile "$DomainName.dns" -ErrorAction Stop
        
        $recs = @("@", "ns1", "www")
        foreach ($rec in $recs) {
            Add-DnsServerResourceRecordA -ZoneName $DomainName -Name $rec -IPv4Address $Script:ServerIP
        }
        
        Write-Host "[OK] Dominio '$DomainName' configurado exitosamente." -ForegroundColor Green
    } catch {
        Write-Error "Error creando zona: $_"
    }
    Read-Host "Presiona Enter..."
}

function Remove-ZoneDomain {
    Clear-Host
    Write-Host "--- ELIMINAR DOMINIO ---" -ForegroundColor Cyan
    
    $DomainName = Read-Host "Nombre del dominio a borrar"
    
    if (Get-DnsServerZone -Name $DomainName -ErrorAction SilentlyContinue) {
        Remove-DnsServerZone -Name $DomainName -Force -Confirm:$false
        Write-Host "[OK] Dominio eliminado." -ForegroundColor Green
    } else {
        Write-Warning "El dominio no existe."
    }
    Read-Host "Presiona Enter..."
}

function Get-ZoneList {
    Clear-Host
    Write-Host "--- DOMINIOS REGISTRADOS ---" -ForegroundColor Cyan
    $zones = Get-DnsServerZone | Where-Object { $_.IsAutoCreated -eq $false }
    
    if ($zones) {
        $zones | Select-Object ZoneName, ZoneType, IsDsIntegrated | Format-Table -AutoSize
    } else {
        Write-Host "No hay zonas configuradas." -ForegroundColor Gray
    }
    Read-Host "Presiona Enter..."
}

function Test-DNSResolution {
    Clear-Host
    Write-Host "--- PRUEBA DE RESOLUCION ---" -ForegroundColor Cyan
    
    # Re-verificamos la IP para asegurar que el mensaje de exito sea correcto
    Get-SystemIP | Out-Null
    
    $Target = Read-Host "Dominio a probar"
    
    Write-Host "`n[TEST] Consultando DNS (NSLOOKUP)..." -ForegroundColor Yellow
    nslookup $Target
    
    Write-Host "`n[TEST] Probando Conectividad (PING)..." -ForegroundColor Yellow
    try {
        Test-Connection -ComputerName $Target -Count 1 -ErrorAction Stop | Select-Object Address, ResponseTime, Status
        Write-Host "[OK] Conexion Exitosa." -ForegroundColor Green
    } catch {
        # Si el ping falla pero nslookup resolvio a TU IP, es exito parcial (Firewall)
        Write-Warning "El Ping fallo (Probablemente Firewall)." 
        Write-Host "NOTA: Si arriba en 'Address' salio $Script:ServerIP, tu DNS funciona perfecto." -ForegroundColor Green
    }
    Read-Host "Presiona Enter..."
}