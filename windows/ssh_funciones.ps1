<#
.SYNOPSIS
    Libreria y Menu de Administracion SSH
#>

function Wait-Action {
    Write-Host "`nPresione cualquier tecla para continuar..." -NoNewline
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Install-SSH-Server {
    Clear-Host
    Write-Host "*** INSTALACION DE SERVIDOR SSH ***`n"
    
    $sshStatus = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    
    if ($sshStatus.State -eq "Installed") {
        Write-Host ">> El servidor OpenSSH ya esta instalado en el sistema."
    } else {
        Write-Host ">> Descargando e instalando OpenSSH Server..."
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
        Write-Host "[*] Paquete instalado correctamente."
    }

    Write-Host ">> Configurando el inicio automatico del servicio..."
    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType 'Automatic'
    
    Write-Host ">> Validando reglas de Firewall (Puerto 22)..."
    $fwRule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $fwRule) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Write-Host "[*] Regla de Firewall creada (Puerto 22 TCP Abierto)."
    } else {
        Write-Host ">> La regla de Firewall ya se encontraba activa."
    }
    
    Write-Host "`n[*] Servidor SSH operativo y listo para conexiones."
    Wait-Action
}

function Verify-SSH-Installation {
    Clear-Host
    Write-Host "*** ESTADO DEL SERVICIO SSH ***`n"
    
    try {
        $sshService = Get-Service sshd -ErrorAction Stop
        Write-Host "--- Servicio Windows (sshd) ---"
        $sshService | Select-Object Name, Status, StartType | Format-Table -AutoSize
        
        if ($sshService.Status -eq "Running") {
            Write-Host "[*] El servicio se esta ejecutando sin problemas."
        } else {
            Write-Host "Aviso: El servicio esta detenido."
        }

        Write-Host "`n--- Regla de Firewall (Puerto 22) ---"
        $fwRule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
        if ($fwRule -and $fwRule.Enabled -eq "True") {
            Write-Host "[*] El puerto 22 se encuentra abierto en el Firewall."
        } else {
            Write-Host "Aviso: El puerto 22 no esta abierto o la regla no existe."
        }
        
    } catch {
        Write-Host "Error: No se detecto el servicio OpenSSH. Ejecute la instalacion primero."
    }
    Wait-Action
}

function ssh_menu {
    do {
        Clear-Host
        Write-Host "=========================================="
        Write-Host "         MODULO DE ACCESO REMOTO SSH"
        Write-Host "=========================================="
        Write-Host ""
        Write-Host " [ 1 ] Instalar y Configurar Servidor SSH"
        Write-Host " [ 2 ] Verificar Estado y Firewall"
        Write-Host " [ 0 ] Retornar al Panel Central"
        Write-Host ""
        
        $Choice = Read-Host "Indique su eleccion"
        
        switch ($Choice.Trim()) {
            '1' { Install-SSH-Server }
            '2' { Verify-SSH-Installation }
            '0' { return }
            default { Write-Host "Opcion invalida." ; Start-Sleep -Seconds 1 }
        }
    } until ($false)
}