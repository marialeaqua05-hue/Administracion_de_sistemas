# ==========================================
# VALIDACIONES DE PUERTO
# ==========================================
Function Validar-Puerto {
    param ([string]$Puerto)

    if (-not ($Puerto -match '^\d+$')) {
        Write-Host "[!] Error: El puerto debe ser un valor numérico válido." -ForegroundColor Red
        return $false
    }

    # Lista negra de puertos reservados
    $PuertosReservados = @(21, 22, 23, 25, 53, 443, 1433, 3306, 5432, 8443)
    if ($Puerto -in $PuertosReservados) {
        Write-Host "[!] Error: El puerto $Puerto está reservado históricamente para otro servicio." -ForegroundColor Red
        return $false
    }

    # Verificar si está en uso actualmente
    $Ocupado = Get-NetTCPConnection -LocalPort $Puerto -ErrorAction SilentlyContinue
    if ($Ocupado) {
        Write-Host "[!] Error: El puerto $Puerto ya está ocupado por otro servicio." -ForegroundColor Red
        return $false
    }

    return $true
}

# ==========================================
# CONSULTA DINÁMICA DE VERSIONES (Chocolatey)
# ==========================================
Function Seleccionar-Version {
    param ([string]$Paquete)
    
    Write-Host "[*] Consultando repositorio (Chocolatey) para: $Paquete..." -ForegroundColor Cyan
    
    # Extraer lista de versiones exactas disponibles
    $SalidaChoco = choco search $Paquete --exact --all-versions --limit-output
    $Versiones = @()
    
    foreach ($Linea in $SalidaChoco) {
        if ($Linea -match "^$Paquete\|(.*)") {
            $Versiones += $Matches[1]
        }
    }

    if ($Versiones.Count -eq 0) {
        Write-Host "[!] No se encontraron versiones en el repositorio." -ForegroundColor Red
        return $null
    }

    Write-Host "Versiones disponibles:"
    for ($i = 0; $i -lt $Versiones.Count; $i++) {
        Write-Host "  $($i + 1)) $($Versiones[$i])"
    }

    while ($true) {
        $Seleccion = Read-Host "Seleccione el número de la versión a instalar"
        if ($Seleccion -match '^\d+$' -and $Seleccion -ge 1 -and $Seleccion -le $Versiones.Count) {
            return $Versiones[$Seleccion - 1]
        } else {
            Write-Host "[!] Selección inválida. Intente de nuevo." -ForegroundColor Yellow
        }
    }
}

# ==========================================
# MÓDULO 1: INTERNET INFORMATION SERVICES (IIS)
# ==========================================
Function Instalar-IIS {
    param ([string]$Puerto)
    
    Write-Host "`n--- Iniciando aprovisionamiento forzoso de IIS ---" -ForegroundColor Green
    
    # Instalamos IIS y el módulo de seguridad (Request Filtering) silenciosamente
    Write-Host "[*] Instalando roles de Windows Server (Web-Server, Web-Filtering)..."
    Install-WindowsFeature -Name Web-Server, Web-Filtering, Web-Mgmt-Tools -IncludeAllSubFeature > $null

    Import-Module WebAdministration

    Write-Host "[*] Configurando puerto $Puerto en IIS Binding..."
    # Eliminamos el binding por defecto del puerto 80 y creamos el nuevo
    Get-WebBinding -Name "Default Web Site" | Remove-WebBinding
    New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port $Puerto -Protocol http

    Write-Host "[*] Aplicando permisos NTFS restrictivos (Directorio Web)..."
    $RutaWeb = "C:\inetpub\wwwroot"
    icacls $RutaWeb /inheritance:r /grant "*S-1-5-32-544:(OI)(CI)F" /grant "IIS_IUSRS:(OI)(CI)RX" /grant "IUSR:(OI)(CI)RX" /q

    Write-Host "[*] Aplicando Hardening y Security Headers exigidos por la rúbrica..."
    # 1. Eliminar firma X-Powered-By
    Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "." -AtElement @{name='X-Powered-By'} -ErrorAction SilentlyContinue
    
    # 2. Ocultar versión del servidor usando Request Filtering (RemoveServerHeader)
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering" -name "removeServerHeader" -value "True"
    
    # 3. Inyectar Security Headers
    Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "." -value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "." -value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue

    # 4. Bloquear métodos HTTP peligrosos (TRACE, TRACK, DELETE)
    $Metodos = @("TRACE", "TRACK", "DELETE")
    foreach ($Metodo in $Metodos) {
        Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering/verbs" -name "." -value @{verb=$Metodo;allowed=$false} -ErrorAction SilentlyContinue
    }

    Write-Host "[*] Creando página web personalizada..."
    $VersionIIS = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp").VersionString
    "<h1>Servidor: IIS - Versión: $VersionIIS - Puerto: $Puerto</h1>" | Out-File "$RutaWeb\index.html" -Encoding utf8

    Write-Host "[*] Configurando Advanced Firewall..."
    New-NetFirewallRule -DisplayName "HTTP-Personalizado-$Puerto" -Direction Inbound -LocalPort $Puerto -Protocol TCP -Action Allow > $null

    Write-Host "[*] Reiniciando servicio para aplicar cambios..."
    Restart-Service W3SVC

    Write-Host "`n[OK] IIS desplegado y asegurado con éxito en el puerto $Puerto." -ForegroundColor Green
}

# MÓDULO 2: NGINX (Windows)

Function Instalar-Nginx {
    param ([string]$Puerto)
    
    Write-Host "`n--- Iniciando aprovisionamiento de Nginx (Win64) ---" -ForegroundColor Green
    
    $VersionElegida = Seleccionar-Version "nginx"
    if (-not $VersionElegida) { return }

    $DirectorioBase = "C:\nginx"
    $ConfigNginx    = "$DirectorioBase\conf\nginx.conf"
    $RutaHtml       = "$DirectorioBase\html\index.html"
    $NginxExe       = "$DirectorioBase\nginx.exe"

    # Si ya existe una instalacion previa, detenerla
    $ProcNginx = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
    if ($ProcNginx) {
        Write-Host "[*] Deteniendo instancia previa de Nginx..."
        $ProcNginx | Stop-Process -Force
        Start-Sleep -Seconds 1
    }

    if (-not (Test-Path $DirectorioBase)) {
        Write-Host "[*] Descargando Nginx $VersionElegida desde nginx.org..."
        $ZipUrl  = "https://nginx.org/download/nginx-$VersionElegida.zip"
        $ZipPath = "$env:TEMP\nginx-$VersionElegida.zip"

        try {
            Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
        } catch {
            Write-Host "[!] Error al descargar Nginx: $_" -ForegroundColor Red
            return
        }

        Write-Host "[*] Extrayendo archivos..."
        Expand-Archive -Path $ZipPath -DestinationPath "$env:TEMP\nginx_extract" -Force
        $Extraido = Get-ChildItem "$env:TEMP\nginx_extract" -Directory | Select-Object -First 1
        Move-Item $Extraido.FullName $DirectorioBase
        Remove-Item $ZipPath -Force
    } else {
        Write-Host "[*] Nginx ya esta instalado en $DirectorioBase, actualizando configuracion..." -ForegroundColor Cyan
    }

    if (-not (Test-Path $NginxExe)) {
        Write-Host "[!] Error: nginx.exe no encontrado en $DirectorioBase" -ForegroundColor Red
        return
    }

    Write-Host "[*] Configurando puerto $Puerto y hardening en nginx.conf..."
    $Contenido = Get-Content $ConfigNginx -Raw

    $Contenido = $Contenido -replace 'listen\s+\d+;', "listen       $Puerto;"

    if ($Contenido -notmatch "server_tokens off") {
        $Hardening = "    server_tokens off;`n    add_header X-Frame-Options SAMEORIGIN;`n    add_header X-Content-Type-Options nosniff;"
        $Contenido = $Contenido -replace '(http\s*\{)', "`$1`n$Hardening"
    }

    [System.IO.File]::WriteAllText($ConfigNginx, $Contenido, [System.Text.UTF8Encoding]::new($false))

    Write-Host "[*] Creando pagina web personalizada..."
    "<h1>Servidor: Nginx Win64 - Version: $VersionElegida - Puerto: $Puerto</h1>" | Out-File $RutaHtml -Encoding utf8

    Write-Host "[*] Configurando Firewall..."
    $RuleName = "Nginx-Custom-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -LocalPort $Puerto -Protocol TCP -Action Allow | Out-Null
    }

    Write-Host "[*] Iniciando Nginx..."
    Start-Process -FilePath $NginxExe -WorkingDirectory $DirectorioBase -WindowStyle Hidden

    Start-Sleep -Seconds 2
    if (Get-Process -Name "nginx" -ErrorAction SilentlyContinue) {
        Write-Host "`n[OK] Nginx $VersionElegida desplegado exitosamente en el puerto $Puerto." -ForegroundColor Green
    } else {
        Write-Host "`n[!] Nginx no inicio. Revisa el log en: $DirectorioBase\logs\error.log" -ForegroundColor Red
    }
}

# INSTALAR APACHE WIN64
Function Instalar-ApacheWin {
    param ([string]$Puerto)
    Write-Host "`n--- Iniciando aprovisionamiento de Apache (Win64) ---" -ForegroundColor Green
    
    $VersionElegida = Seleccionar-Version "apache-httpd"
    if (-not $VersionElegida) { return }

    Write-Host "[*] Instalando Apache silenciosamente (Version: $VersionElegida)..."
    choco install apache-httpd --version $VersionElegida -y --force | Out-Null

    # Buscar httpd.exe dinamicamente
    Write-Host "[*] Buscando ruta de instalacion..." -ForegroundColor Cyan
    $HttpdExe = Get-ChildItem -Path "C:\tools", "C:\ProgramData\chocolatey\lib", "C:\Apache24", "$env:APPDATA" `
                -Recurse -Filter "httpd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $HttpdExe) {
        Write-Host "[!] Error critico: No se encontro httpd.exe en el sistema." -ForegroundColor Red
        return
    }

    $RutaApache   = $HttpdExe.DirectoryName | Split-Path -Parent
    $ConfigApache = "$RutaApache\conf\httpd.conf"
    $RutaHtml     = "$RutaApache\htdocs\index.html"

    Write-Host "[OK] Apache encontrado en: $RutaApache" -ForegroundColor Green

    if (-not (Test-Path $ConfigApache)) {
        Write-Host "[!] Error: httpd.conf no encontrado en $ConfigApache" -ForegroundColor Red
        return
    }

    Write-Host "[*] Configurando puerto $Puerto y hardening en httpd.conf..."
    $Contenido = Get-Content $ConfigApache -Raw

    # Cambio de puerto
    $Contenido = $Contenido -replace '(?m)^Listen\s+\d+', "Listen $Puerto"

    # Deshabilitar SSL para evitar conflicto con puerto 443
    $Contenido = $Contenido -replace '(?m)^(LoadModule ssl_module)',        '#$1'
    $Contenido = $Contenido -replace '(?m)^(Include conf/extra/httpd-ssl.conf)', '#$1'
    $Contenido = $Contenido -replace '(?m)^(LoadModule socache_shmcb_module)', '#$1'

    # Hardening: ocultar version
    if ($Contenido -match '(?m)^ServerTokens\s+\w+') {
        $Contenido = $Contenido -replace '(?m)^ServerTokens\s+\w+', "ServerTokens Prod"
    } else {
        $Contenido += "`nServerTokens Prod"
    }
    if ($Contenido -notmatch "ServerSignature") {
        $Contenido += "`nServerSignature Off"
    }

    # Asegurar mod_headers habilitado
    $Contenido = $Contenido -replace '(?m)^#(LoadModule headers_module)', '$1'

    # Security headers solo si no existen
    if ($Contenido -notmatch "X-Frame-Options") {
        $Contenido += "`nHeader always set X-Frame-Options `"SAMEORIGIN`""
    }
    if ($Contenido -notmatch "X-Content-Type-Options") {
        $Contenido += "`nHeader always set X-Content-Type-Options `"nosniff`""
    }

    # Guardar sin BOM
    [System.IO.File]::WriteAllText($ConfigApache, $Contenido, [System.Text.UTF8Encoding]::new($false))

    Write-Host "[*] Creando pagina web personalizada..."
    "<h1>Servidor: Apache Win64 - Version: $VersionElegida - Puerto: $Puerto</h1>" | `
        Out-File $RutaHtml -Encoding utf8

    Write-Host "[*] Configurando Firewall..."
    $RuleName = "Apache-Custom-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -LocalPort $Puerto -Protocol TCP -Action Allow | Out-Null
    }

    # Desinstalar servicio previo si existe
    $ServicioExiste = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    if ($ServicioExiste) {
        Write-Host "[*] Desinstalando servicio Apache previo..."
        & "$RutaApache\bin\httpd.exe" -k uninstall | Out-Null
        Start-Sleep -Seconds 1
    }

    Write-Host "[*] Registrando e iniciando servicio Apache..."
    & "$RutaApache\bin\httpd.exe" -k install | Out-Null
    Start-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $Servicio = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    if ($Servicio -and $Servicio.Status -eq "Running") {
        Write-Host "`n[OK] Apache $VersionElegida desplegado exitosamente en el puerto $Puerto." -ForegroundColor Green
    } else {
        Write-Host "`n[!] Apache no inicio. Revisa: $RutaApache\logs\error.log" -ForegroundColor Red
    }
}

# MENÚ HTTP
Function Menu-HTTP {
    do {
        Clear-Host
        Write-Host "=========================================================" -ForegroundColor Cyan
        Write-Host "      APROVISIONAMIENTO WEB AUTOMATIZADO (WINDOWS)" -ForegroundColor Cyan
        Write-Host "=========================================================" -ForegroundColor Cyan
        Write-Host " Seleccione el servicio HTTP a desplegar:"
        Write-Host "  1) Internet Information Services (IIS)"
        Write-Host "  2) Nginx (Win64)"
	Write-Host "  3) Apache (Win64)"
        Write-Host "  0) Regresar al Menu Principal"
        Write-Host "=========================================================" -ForegroundColor Cyan
        
        $Opcion = Read-Host "Ingrese una opcion"
        
        if ($Opcion -eq '0') { break }
        
        if ($Opcion -notin @('1', '2', '3')) {
            Write-Host "[!] Error: Opcion no valida." -ForegroundColor Red
            Pause
            continue
        }

        $PuertoValido = $false
        $PuertoInput = ""
        while (-not $PuertoValido) {
            $PuertoInput = Read-Host "Ingrese el puerto de escucha deseado (ej. 80, 8080)"
            $PuertoValido = Validar-Puerto -Puerto $PuertoInput
        }

        switch ($Opcion) {
            '1' { Instalar-IIS -Puerto $PuertoInput }
            '2' { Instalar-Nginx -Puerto $PuertoInput }
	    '3' { Instalar-ApacheWin -Puerto $PuertoInput }
        }

        Write-Host ""
        Pause
    } until ($false)
}