<#
.SYNOPSIS
    Libreria de funciones de DNS Server (Seguridad y Validacion Integrada)
#>

$Script:ServerIP = $null
$Script:Interface = $Global:InterfaceAlias

# --- NUEVA FUNCIÓN DE VALIDACIÓN ESTRICTA ---
function Test-ValidIP ($IP) {
    # 1. ¿Es un formato IP reconocible?
    if (-not ($IP -as [System.Net.IPAddress])) { return $false }
    # 2. Bloquear IPs que no pueden ser servidores DNS
    if ($IP -match "^0\.") { return $false }       # Bloquea 0.0.0.0
    if ($IP -match "^127\.") { return $false }     # Bloquea Loopback
    if ($IP -match "^169\.254\.") { return $false } # Bloquea APIPA de Windows
    
    return $true
}

function Get-SystemIP {
    # Utilizamos la nueva validacion para filtrar IPs basura del sistema
    $ipConfig = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
        (Test-ValidIP $_.IPAddress) -and $_.PrefixOrigin -eq "Manual"
    } | Select-Object -First 1
    
    if (-not $ipConfig) {
        $ipConfig = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
            (Test-ValidIP $_.IPAddress)
        } | Select-Object -First 1
    }
    
    if ($ipConfig) {
        $Script:ServerIP = $ipConfig.IPAddress
        $Script:Interface = $ipConfig.InterfaceAlias
        return $true
    }
    return $false
}

function Wait-Action {
    Write-Host "`nPresione cualquier tecla para continuar..." -NoNewline
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Install-DNS-Feature {
    Clear-Host
    Write-Host "*** PREPARACION DE SERVIDOR DNS ***`n"
    
    if (Get-WindowsFeature DNS | Where-Object Installed) {
        Write-Host ">> Modulo DNS activo en el sistema."
    } else {
        Write-Host ">> Desplegando caracteristica DNS Server..."
        Install-WindowsFeature DNS -IncludeManagementTools | Out-Null
        Write-Host ">> Finalizado."
    }

    if (Get-SystemIP) {
        Write-Host "`n>> Redirigiendo consultas DNS locales..."
        Write-Host "   IP maestra validada: $Script:ServerIP"
        
        $adapters = Get-NetAdapter | Where-Object Status -eq "Up"
        foreach ($nic in $adapters) {
            Write-Host "   - Ajustando adaptador: $($nic.Name)"
            Set-DnsClientServerAddress -InterfaceAlias $nic.Name -ServerAddresses $Script:ServerIP
        }
        
        Clear-DnsClientCache
        Write-Host "[*] El servidor responde ahora unicamente a sus propios registros."
    } else {
        Write-Host "Error critico: No se identifico IP valida en el servidor."
    }
    Wait-Action
}

function New-ZoneDomain {
    Clear-Host
    Write-Host "*** ALTA DE NUEVO DOMINIO ***`n"
    
    if (-not (Get-SystemIP)) { Write-Host "Se requiere configurar una IP valida en la red primero."; Wait-Action; return }

    $DomainName = Read-Host "Especifique el nombre DNS (Ej: empresa.local)"
    if ([string]::IsNullOrWhiteSpace($DomainName)) { return }

    if (Get-DnsServerZone -Name $DomainName -ErrorAction SilentlyContinue) {
        Write-Host "Aviso: Zona ya registrada."
        Wait-Action; return
    }

    Write-Host "`n>> Procesando Zona de Busqueda Directa..."
    try {
        Add-DnsServerPrimaryZone -Name $DomainName -ZoneFile "$DomainName.dns" -ErrorAction Stop
        
        $recs = @("@", "ns1", "www")
        foreach ($rec in $recs) {
            Add-DnsServerResourceRecordA -ZoneName $DomainName -Name $rec -IPv4Address $Script:ServerIP | Out-Null
        }
        Write-Host "[*] Zona y registros base creados."

        Write-Host "`n>> Procesando Zona de Busqueda Inversa (PTR)..."
        
        $Octets = $Script:ServerIP.Split(".")
        $NetworkId = "$($Octets[0]).$($Octets[1]).$($Octets[2]).0/24"
        $ReverseZoneName = "$($Octets[2]).$($Octets[1]).$($Octets[0]).in-addr.arpa"
        $HostOctet = $Octets[3]

        if (-not (Get-DnsServerZone -Name $ReverseZoneName -ErrorAction SilentlyContinue)) {
            Write-Host "   - Generando archivo para red $NetworkId"
            Add-DnsServerPrimaryZone -NetworkId $NetworkId -ZoneFile "$ReverseZoneName.dns" | Out-Null
        }

        Add-DnsServerResourceRecordPtr -Name $HostOctet -ZoneName $ReverseZoneName -PtrDomainName "$DomainName" -ErrorAction SilentlyContinue | Out-Null
        Write-Host "[*] Puntero inverso (PTR) configurado correctamente."

    } catch {
        Write-Host "Fallo durante la configuracion: $_"
    }
    Wait-Action
}

function Remove-ZoneDomain {
    Clear-Host
    Write-Host "*** BAJA DE DOMINIO ***`n"
    
    $DomainName = Read-Host "Indique el dominio a remover del sistema"
    
    if (Get-DnsServerZone -Name $DomainName -ErrorAction SilentlyContinue) {
        Remove-DnsServerZone -Name $DomainName -Force -Confirm:$false
        Write-Host "[*] Dominio y registros vinculados fueron removidos."
    } else {
        Write-Host "El recurso indicado no se encuentra activo."
    }
    Wait-Action
}

function Get-ZoneList {
    Clear-Host
    Write-Host "*** INVENTARIO DE ZONAS DNS ***`n"
    $zones = Get-DnsServerZone | Where-Object { $_.IsAutoCreated -eq $false }
    
    if ($zones) {
        $zones | Select-Object ZoneName, ZoneType, IsDsIntegrated | Format-Table -AutoSize
    } else {
        Write-Host "No existen registros en la base de datos."
    }
    Wait-Action
}

function Test-DNSResolution {
    Clear-Host
    Write-Host "*** DIAGNOSTICO DE RESOLUCION ***`n"
    
    Get-SystemIP | Out-Null
    
    $Target = Read-Host "Escriba el dominio a consultar"
    if ([string]::IsNullOrWhiteSpace($Target)) { return }
    
    Write-Host "`n--- Test Directo (A) ---"
    nslookup $Target
    
    Write-Host "`n--- Test Inverso (PTR) ---"
    nslookup $Script:ServerIP
    
    Write-Host "`n--- Verificacion ICMP ---"
    try {
        Test-Connection -ComputerName $Target -Count 1 -ErrorAction Stop | Select-Object Address, ResponseTime, Status
        Write-Host "[*] Ping recibido."
    } catch {
        Write-Host "Aviso: Ping denegado. (Puede ser normal si el Firewall bloquea ICMP)." 
    }
    Wait-Action
}

function dns_menu {
    do {
        Clear-Host
        Write-Host "=========================================="
        Write-Host "         MODULO DE RESOLUCION DNS"
        Write-Host "=========================================="
        Write-Host ""
        Write-Host " [ 1 ] Preparar Servidor y Forzar Localhost"
        Write-Host " [ 2 ] Registrar Dominio (A / PTR)"
        Write-Host " [ 3 ] Remover Dominio Existente"
        Write-Host " [ 4 ] Visualizar Zonas Activas"
        Write-Host " [ 5 ] Lanzar Diagnostico (Nslookup)"
        Write-Host " [ 0 ] Retornar al Panel Central"
        Write-Host ""
        
        $Selection = Read-Host "Indique su eleccion"
        
        switch ($Selection.Trim()) {
            '1' { Install-DNS-Feature }
            '2' { New-ZoneDomain }
            '3' { Remove-ZoneDomain }
            '4' { Get-ZoneList }
            '5' { Test-DNSResolution }
            '0' { return }
            default { 
                Write-Host "Entrada invalida." 
                Start-Sleep -Seconds 1
            }
        }
    } until ($false)
}