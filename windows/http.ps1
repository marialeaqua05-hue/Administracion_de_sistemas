# ============================================================
# Archivo: http.ps1
# Practica 7 - Aprovisionamiento HTTP con SSL/TLS y FTP
# Windows Server 2022
# ============================================================

# ==========================================
# CONFIGURACION GLOBAL
# ==========================================
$FTP_IP       = "192.168.56.103"
$FTP_USER     = "anonymous"
$FTP_PASS     = ""
$FTP_BASE     = "ftp://${FTP_IP}/http/Windows"
$CERT_DNS     = "www.reprobados.com"
$TEMP_DIR     = "C:\temp"
$OPENSSL_PATH = "C:\Program Files\OpenSSL-Win64\bin"

# Agregar OpenSSL al PATH si existe
if (Test-Path $OPENSSL_PATH) {
    if ($env:PATH -notmatch [regex]::Escape($OPENSSL_PATH)) {
        $env:PATH += ";$OPENSSL_PATH"
    }
}

# ==========================================
# VALIDACION DE PUERTO
# ==========================================
Function Validar-Puerto {
    param ([string]$Puerto)

    if (-not ($Puerto -match '^\d+$')) {
        Write-Host "[!] Error: El puerto debe ser un valor numerico valido." -ForegroundColor Red
        return $false
    }

    $PuertosReservados = @(21, 22, 23, 25, 53, 1433, 3306, 5432)
    if ([int]$Puerto -in $PuertosReservados) {
        Write-Host "[!] Error: El puerto $Puerto esta reservado para otro servicio." -ForegroundColor Red
        return $false
    }

    $Ocupado = Get-NetTCPConnection -LocalPort ([int]$Puerto) -ErrorAction SilentlyContinue
    if ($Ocupado) {
        Write-Host "[!] Error: El puerto $Puerto ya esta ocupado." -ForegroundColor Red
        return $false
    }

    return $true
}

# ==========================================
# CONSULTA DINAMICA DE VERSIONES (Chocolatey)
# ==========================================
Function Seleccionar-Version {
    param ([string]$Paquete)

    Write-Host "[*] Consultando repositorio (Chocolatey) para: $Paquete..." -ForegroundColor Cyan

    $SalidaChoco = choco search $Paquete --exact --all-versions --limit-output 2>$null
    $Versiones = @()

    foreach ($Linea in $SalidaChoco) {
        if ($Linea -match "^$Paquete\|(.*)") {
            $Versiones += $Matches[1]
        }
    }

    if ($Versiones.Count -eq 0) {
        Write-Host "[!] No se encontraron versiones en Chocolatey." -ForegroundColor Red
        return $null
    }

    if ($Versiones.Count -eq 1) {
        Write-Host "[*] Unica version disponible: $($Versiones[0])" -ForegroundColor Cyan
        return $Versiones[0]
    }

    Write-Host "Versiones disponibles:"
    for ($i = 0; $i -lt $Versiones.Count; $i++) {
        Write-Host "  $($i+1)) $($Versiones[$i])"
    }

    while ($true) {
        $Sel = Read-Host "Seleccione el numero de la version"
        if ($Sel -match '^\d+$' -and [int]$Sel -ge 1 -and [int]$Sel -le $Versiones.Count) {
            return $Versiones[[int]$Sel - 1]
        }
        Write-Host "[!] Seleccion invalida." -ForegroundColor Yellow
    }
}

# ==========================================
# CLIENTE FTP DINAMICO (35% Rubrica)
# ==========================================
Function Obtener-Desde-FTP {
    param ([string]$Servicio)

    Write-Host "[*] Conectando al repositorio FTP: $FTP_BASE/$Servicio/" -ForegroundColor Yellow
    if (-not (Test-Path $TEMP_DIR)) { New-Item -Path $TEMP_DIR -ItemType Directory | Out-Null }

    $Cred = New-Object System.Net.NetworkCredential($FTP_USER, $FTP_PASS)

    try {
        $UrlDir = "$FTP_BASE/$Servicio/"
        $Request = [System.Net.FtpWebRequest]::Create($UrlDir)
        $Request.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $Request.Credentials = $Cred
        $Request.UsePassive = $true
        $Request.UseBinary = $false
        $Request.Timeout = 10000

        $Response = $Request.GetResponse()
        $MS = New-Object System.IO.MemoryStream
        $Buffer = New-Object byte[] 4096
        $Stream = $Response.GetResponseStream()
        do {
            $Read = $Stream.Read($Buffer, 0, $Buffer.Length)
            if ($Read -gt 0) { $MS.Write($Buffer, 0, $Read) }
        } while ($Read -gt 0)
        $Stream.Close(); $Response.Close()
        $RawData = [System.Text.Encoding]::UTF8.GetString($MS.ToArray())

        # Formato IIS FTP: MM-DD-YY  HH:MMAM  <size> nombre
        # IMPORTANTE: usar @() para forzar array aunque haya un solo elemento
        $Archivos = @($RawData.Split([char]10) | ForEach-Object {
            $l = $_.Trim().TrimEnd([char]13)
            if ($l -match "^\d{2}-\d{2}-\d{2}") {
                $p = $l -split "\s+", 4
                if ($p.Count -eq 4 -and $p[3] -match "\.(zip|msi|exe)$") {
                    $p[3].Trim()
                }
            }
        } | Where-Object { $_ })

        if ($Archivos.Count -eq 0) {
            Write-Host "[!] No se encontraron binarios (.zip, .msi, .exe) en $UrlDir" -ForegroundColor Red
            return $null
        }

    } catch {
        Write-Host "[!] Error al conectar al FTP: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    Write-Host "Binarios disponibles en FTP ($Servicio):"
    for ($i = 0; $i -lt $Archivos.Count; $i++) {
        Write-Host "  $($i+1)) $($Archivos[$i])"
    }

    $Sel = Read-Host "Seleccione el numero del archivo"
    if (-not ($Sel -match '^\d+$') -or [int]$Sel -lt 1 -or [int]$Sel -gt $Archivos.Count) {
        Write-Host "[!] Seleccion invalida." -ForegroundColor Red
        return $null
    }

    $Binario  = $Archivos[[int]$Sel - 1]
    $UrlBin   = "$FTP_BASE/$Servicio/$Binario"
    $UrlHash  = "$FTP_BASE/$Servicio/$Binario.sha256"
    $DestBin  = "$TEMP_DIR\$Binario"
    $DestHash = "$TEMP_DIR\$Binario.sha256"

    # Descargar binario
    Write-Host "[*] Descargando $Binario desde FTP..." -ForegroundColor Cyan
    try {
        $WebClient = New-Object System.Net.WebClient
        $WebClient.Credentials = $Cred
        $WebClient.DownloadFile($UrlBin, $DestBin)
    } catch {
        Write-Host "[!] Error al descargar binario: $_" -ForegroundColor Red
        return $null
    }

    # Descargar hash
    Write-Host "[*] Descargando archivo de integridad (.sha256)..." -ForegroundColor Cyan
    try {
        $WebClient.DownloadFile($UrlHash, $DestHash)
    } catch {
        Write-Host "[!] Error al descargar .sha256: $_" -ForegroundColor Red
        return $null
    }

    # Validar integridad (15% Rubrica)
    Write-Host "[*] Verificando integridad SHA256..." -ForegroundColor Cyan
    $HashCalc = (Get-FileHash $DestBin -Algorithm SHA256).Hash.ToLower()
    $HashExp  = ((Get-Content $DestHash -Raw).Trim() -split "\s+")[0].ToLower()

    if ($HashCalc -eq $HashExp) {
        Write-Host "[OK] Integridad validada: SHA256 coincide." -ForegroundColor Green
        return $DestBin
    } else {
        Write-Host "[!] ERROR DE INTEGRIDAD: Hash no coincide." -ForegroundColor Red
        Write-Host "    Calculado : $HashCalc"
        Write-Host "    Esperado  : $HashExp"
        Remove-Item $DestBin -Force -ErrorAction SilentlyContinue
        return $null
    }
}

# ==========================================
# SELECCION DE ORIGEN (WEB o FTP)
# ==========================================
Function Obtener-Origen {
    param ([string]$Servicio)
    Write-Host ("`nSeleccione el origen de instalacion para " + $Servicio + ":") -ForegroundColor Cyan
    Write-Host "  1) WEB (Chocolatey / nginx.org)"
    Write-Host "  2) FTP (Repositorio Privado - $FTP_IP)"
    $Origen = Read-Host "Opcion"
    return $Origen
}

# ==========================================
# SSL/TLS - GENERACION DE CERTIFICADO
# ==========================================
Function Generar-Certificado {
    Write-Host "[*] Generando certificado autofirmado para $CERT_DNS..." -ForegroundColor Cyan
    $Cert = New-SelfSignedCertificate `
        -DnsName $CERT_DNS `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -NotAfter (Get-Date).AddDays(365) `
        -KeyAlgorithm RSA `
        -KeyLength 2048
    Write-Host "[OK] Certificado generado. Thumbprint: $($Cert.Thumbprint)" -ForegroundColor Green
    return $Cert
}

# ==========================================
# SSL/TLS - EXPORTAR CERT Y KEY CON OPENSSL
# ==========================================
Function Exportar-CertPEM {
    param ([object]$Cert, [string]$CertDir, [string]$Nombre = "reprobados")

    if (-not (Test-Path $CertDir)) { New-Item -Path $CertDir -ItemType Directory | Out-Null }

    $CertFile = "$CertDir\$Nombre.crt"
    $KeyFile  = "$CertDir\$Nombre.key"

    # Exportar certificado como PEM
    $CertBytes = $Cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $CertB64   = [Convert]::ToBase64String($CertBytes)
    $PemLines  = $CertB64 -replace "(.{64})", "`$1`n"
    [System.IO.File]::WriteAllText($CertFile, "-----BEGIN CERTIFICATE-----`n$PemLines`n-----END CERTIFICATE-----`n")

    # Exportar clave via openssl
    $PfxPath = "$env:TEMP\temp_cert.pfx"
    $PfxPwd  = ConvertTo-SecureString "TempPass123!" -AsPlainText -Force
    Export-PfxCertificate -Cert $Cert -FilePath $PfxPath -Password $PfxPwd | Out-Null

    $OpenSSL = Get-Command openssl -ErrorAction SilentlyContinue
    if ($OpenSSL) {
        & openssl pkcs12 -in $PfxPath -nocerts -nodes -out $KeyFile -passin pass:TempPass123! 2>$null
        Write-Host "[OK] Clave privada exportada correctamente." -ForegroundColor Green
    } else {
        Write-Host "[!] OpenSSL no encontrado en PATH." -ForegroundColor Yellow
    }
    Remove-Item $PfxPath -Force -ErrorAction SilentlyContinue

    return @{ CertFile = $CertFile; KeyFile = $KeyFile }
}

# ==========================================
# SSL/TLS - IIS (35% Rubrica)
# ==========================================
Function Configurar-SSL-IIS {
    param ([string]$PuertoHTTP)
    Write-Host "[*] Configurando SSL/TLS en IIS (puerto 443)..." -ForegroundColor Cyan

    $Cert = Generar-Certificado
    $Hash = $Cert.GetCertHashString()

    # Eliminar binding y sslcert previos
    Get-WebBinding -Name "Default Web Site" -Protocol "https" -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
    netsh http delete sslcert ipport=0.0.0.0:443 2>$null | Out-Null

    # Agregar binding HTTPS en puerto 443
    New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port 443 -Protocol "https" -ErrorAction SilentlyContinue

    # Asociar certificado con almacen MY
    $AppId = '{4dc3e181-e14b-4a21-b022-59fc669b0914}'
    netsh http add sslcert ipport=0.0.0.0:443 certhash=$Hash appid=$AppId certstorename=MY | Out-Null

    # HSTS y redireccion HTTP -> HTTPS via web.config
    $WebConfig = "C:\inetpub\wwwroot\web.config"
    $HSTSConfig = @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <httpProtocol>
      <customHeaders>
        <add name="Strict-Transport-Security" value="max-age=31536000; includeSubDomains" />
      </customHeaders>
    </httpProtocol>
    <rewrite>
      <rules>
        <rule name="HTTP to HTTPS" stopProcessing="true">
          <match url="(.*)" />
          <conditions>
            <add input="{HTTPS}" pattern="^OFF$" />
          </conditions>
          <action type="Redirect" url="https://192.168.56.103/" redirectType="Permanent" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
'@
    [System.IO.File]::WriteAllText($WebConfig, $HSTSConfig, [System.Text.UTF8Encoding]::new($false))

    # Firewall
    $RuleName = "HTTPS-IIS-443"
    if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow | Out-Null
    }

    Stop-Service W3SVC; Stop-Service WAS -Force
    Start-Sleep -Seconds 2
    Start-Service WAS; Start-Service W3SVC
    Write-Host "[OK] SSL/TLS activo en IIS puerto 443. Redireccion HTTP->HTTPS configurada." -ForegroundColor Green
}

# ==========================================
# SSL/TLS - NGINX WINDOWS (35% Rubrica)
# ==========================================
Function Configurar-SSL-Nginx {
    param ([string]$DirectorioBase, [string]$PuertoHTTP)

    Write-Host "[*] Configurando SSL/TLS en Nginx Windows (puerto 8443)..." -ForegroundColor Cyan

    $Cert = Generar-Certificado
    Exportar-CertPEM -Cert $Cert -CertDir "$DirectorioBase\conf\ssl" | Out-Null

    # Escribir nginx.conf completo
    $NginxConf = @"
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server_tokens off;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

    server {
        listen       $PuertoHTTP;
        server_name  $CERT_DNS;
        return 301 https://`$host:8443`$request_uri;
    }

    server {
        listen       8443 ssl;
        server_name  $CERT_DNS;

        ssl_certificate      C:/nginx/conf/ssl/reprobados.crt;
        ssl_certificate_key  C:/nginx/conf/ssl/reprobados.key;
        ssl_protocols        TLSv1.2;
        ssl_ciphers          HIGH:!aNULL:!MD5;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-Content-Type-Options nosniff;

        location / {
            root   html;
            index  index.html index.htm;
        }
    }
}
"@
    [System.IO.File]::WriteAllText("$DirectorioBase\conf\nginx.conf", $NginxConf, [System.Text.UTF8Encoding]::new($false))

    # Firewall
    $RuleName = "HTTPS-Nginx-8443"
    if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -LocalPort 8443 -Protocol TCP -Action Allow | Out-Null
    }

    Write-Host "[OK] SSL/TLS configurado en Nginx Windows. Puerto 8443 activo." -ForegroundColor Green
}

# ==========================================
# SSL/TLS - APACHE WINDOWS (35% Rubrica)
# ==========================================
Function Configurar-SSL-Apache {
    param ([string]$RutaApache, [string]$PuertoHTTP)

    Write-Host "[*] Configurando SSL/TLS en Apache Windows (puerto 8444)..." -ForegroundColor Cyan

    $Cert = Generar-Certificado
    Exportar-CertPEM -Cert $Cert -CertDir "$RutaApache\conf\ssl" | Out-Null

    $ConfigApache = "$RutaApache\conf\httpd.conf"
    $Contenido = Get-Content $ConfigApache -Raw

    # Habilitar modulos
    $Contenido = $Contenido -replace '(?m)^#(LoadModule ssl_module)',           '$1'
    $Contenido = $Contenido -replace '(?m)^#(LoadModule socache_shmcb_module)', '$1'
    $Contenido = $Contenido -replace '(?m)^#(LoadModule headers_module)',       '$1'

    # Quitar Listen 8444 duplicado
    $Contenido = $Contenido -replace "(?m)^Listen 8444\r?\n", ""

    # Agregar VirtualHost SSL
    if ($Contenido -notmatch "VirtualHost \*:8444") {
        $VHostSSL = @"

# --- VirtualHost SSL Automatizado ---
Listen 8444

<VirtualHost *:8444>
    ServerName $CERT_DNS
    SSLEngine on
    SSLCertificateFile    "$RutaApache/conf/ssl/reprobados.crt"
    SSLCertificateKeyFile "$RutaApache/conf/ssl/reprobados.key"
    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite        HIGH:!aNULL:!MD5
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff
    DocumentRoot "$RutaApache/htdocs"
</VirtualHost>

# Redireccion HTTP -> HTTPS
<VirtualHost *:$PuertoHTTP>
    ServerName $CERT_DNS
    Redirect permanent / https://$CERT_DNS/
</VirtualHost>
"@
        $Contenido += $VHostSSL
    }

    [System.IO.File]::WriteAllText($ConfigApache, $Contenido, [System.Text.UTF8Encoding]::new($false))

    # Corregir httpd-ssl.conf - cambiar puerto y quitar Listen para evitar duplicado
    $SslConf = "$RutaApache\conf\extra\httpd-ssl.conf"
    if (Test-Path $SslConf) {
        $sc = Get-Content $SslConf -Raw
        $sc = $sc -replace "(?m)^Listen 443.*
?
", ""
        $sc = $sc -replace "VirtualHost _default_:443", "VirtualHost _default_:8444"
        [System.IO.File]::WriteAllText($SslConf, $sc, [System.Text.UTF8Encoding]::new($false))
    }

    # Corregir httpd-ahssl.conf - quitar Listen para evitar duplicado y corregir rutas
    $AhSslConf = "$RutaApache\conf\extra\httpd-ahssl.conf"
    if (Test-Path $AhSslConf) {
        $ac = Get-Content $AhSslConf -Raw
        $ac = $ac -replace "(?m)^Listen 443.*
?
", ""
        # Corregir rutas hardcodeadas ${SRVROOT} y C:/Apache24
        $RutaApacheSlash = $RutaApache -replace "\\", "/"
        $ac = $ac -replace '\$\{SRVROOT\}', $RutaApacheSlash
        $ac = $ac -replace 'C:/Apache24(?!_FTP)[^/]*/', "$RutaApacheSlash/"
        [System.IO.File]::WriteAllText($AhSslConf, $ac, [System.Text.UTF8Encoding]::new($false))
    }

    # Firewall
    $RuleName = "HTTPS-Apache-8444"
    if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -LocalPort 8444 -Protocol TCP -Action Allow | Out-Null
    }

    Write-Host "[OK] SSL/TLS configurado en Apache Windows. Puerto 8444 activo." -ForegroundColor Green
}

# ==========================================
# RESUMEN AUTOMATIZADO DE VERIFICACION
# ==========================================
Function Mostrar-Resumen {
    Write-Host "`n=========================================================" -ForegroundColor Cyan
    Write-Host "   RESUMEN DE VERIFICACION DE SERVICIOS HTTP" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    $Servicios = @(
        @{ Nombre="IIS";         PuertoSSL=443;  Servicio="W3SVC" },
        @{ Nombre="Nginx";       PuertoSSL=8443; Servicio="nginx" },
        @{ Nombre="Apache Win";  PuertoSSL=8444; Servicio="Apache2.4" }
    )

    foreach ($Svc in $Servicios) {
        $Estado = "DETENIDO"
        $SSL    = "NO"

        if ($Svc.Servicio -eq "nginx") {
            if (Get-Process -Name "nginx" -ErrorAction SilentlyContinue) { $Estado = "ACTIVO" }
        } else {
            $Srv = Get-Service -Name $Svc.Servicio -ErrorAction SilentlyContinue
            if ($Srv -and $Srv.Status -eq "Running") { $Estado = "ACTIVO" }
        }

        $PuertoSSL = Get-NetTCPConnection -LocalPort $Svc.PuertoSSL -State Listen -ErrorAction SilentlyContinue
        if ($PuertoSSL) { $SSL = "SI (puerto $($Svc.PuertoSSL))" }

        $Color = if ($Estado -eq "ACTIVO") { "Green" } else { "Red" }
        Write-Host ("  {0,-15} Estado: {1,-10} SSL: {2}" -f $Svc.Nombre, $Estado, $SSL) -ForegroundColor $Color
    }

    Write-Host "=========================================================" -ForegroundColor Cyan

    $Cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match "reprobados" } | Select-Object -First 1
    if ($Cert) {
        Write-Host "[OK] Certificado: $($Cert.Subject)" -ForegroundColor Green
        Write-Host "     Expira    : $($Cert.NotAfter)" -ForegroundColor Cyan
        Write-Host "     Thumbprint: $($Cert.Thumbprint)" -ForegroundColor Cyan
    } else {
        Write-Host "[!] No se encontro certificado para $CERT_DNS" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ==========================================
# MODULO 1: IIS
# ==========================================
Function Instalar-IIS {
    param ([string]$Puerto)

    Write-Host "`n--- Iniciando aprovisionamiento de IIS ---" -ForegroundColor Green

    $Origen = Obtener-Origen -Servicio "IIS"
    if ($Origen -eq '2') {
        Write-Host "[!] IIS es un rol de Windows, se instala localmente." -ForegroundColor Yellow
    }

    Write-Host "[*] Instalando roles de Windows Server (IIS)..."
    Install-WindowsFeature -Name Web-Server, Web-Filtering, Web-Mgmt-Tools, Web-Url-Auth -IncludeAllSubFeature | Out-Null
    Import-Module WebAdministration

    Write-Host "[*] Configurando puerto $Puerto en IIS..."
    Get-WebBinding -Name "Default Web Site" | Remove-WebBinding
    New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port $Puerto -Protocol http

    Write-Host "[*] Aplicando permisos NTFS..."
    $RutaWeb = "C:\inetpub\wwwroot"
    icacls $RutaWeb /inheritance:r /grant "*S-1-5-32-544:(OI)(CI)F" /grant "IIS_IUSRS:(OI)(CI)RX" /grant "IUSR:(OI)(CI)RX" /q | Out-Null

    Write-Host "[*] Aplicando Hardening..."
    Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "." -AtElement @{name='X-Powered-By'} -ErrorAction SilentlyContinue
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering" -name "removeServerHeader" -value "True"
    Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "." -value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "." -value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue
    foreach ($Metodo in @("TRACE","TRACK","DELETE")) {
        Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering/verbs" -name "." -value @{verb=$Metodo;allowed=$false} -ErrorAction SilentlyContinue
    }

    $VersionIIS = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp").VersionString
    "<h1>Servidor: IIS - Version: $VersionIIS - Puerto: $Puerto</h1>" | Out-File "$RutaWeb\index.html" -Encoding utf8

    New-NetFirewallRule -DisplayName "HTTP-IIS-$Puerto" -Direction Inbound -LocalPort $Puerto -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null

    Restart-Service W3SVC
    Write-Host "`n[OK] IIS desplegado en puerto $Puerto." -ForegroundColor Green

    $SSL = Read-Host "`nDesea activar SSL/TLS en IIS? [S/N]"
    if ($SSL -match '^[Ss]$') {
        Configurar-SSL-IIS -PuertoHTTP $Puerto
    }
}

# ==========================================
# MODULO 2: NGINX WINDOWS
# ==========================================
Function Instalar-Nginx {
    param ([string]$Puerto)

    Write-Host "`n--- Iniciando aprovisionamiento de Nginx (Win64) ---" -ForegroundColor Green

    $DirectorioBase = "C:\nginx"
    $ConfigNginx    = "$DirectorioBase\conf\nginx.conf"
    $RutaHtml       = "$DirectorioBase\html\index.html"
    $NginxExe       = "$DirectorioBase\nginx.exe"

    Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1

    $Origen = Obtener-Origen -Servicio "Nginx"
    $VersionElegida = $null

    if ($Origen -eq '2') {
        $Binario = Obtener-Desde-FTP -Servicio "Nginx"
        if (-not $Binario) { return }

        Write-Host "[*] Extrayendo Nginx desde FTP..."
        if (-not (Test-Path $DirectorioBase)) { New-Item -Path $DirectorioBase -ItemType Directory | Out-Null }
        Expand-Archive -Path $Binario -DestinationPath "$env:TEMP\nginx_ftp" -Force
        $Extraido = Get-ChildItem "$env:TEMP\nginx_ftp" -Directory | Select-Object -First 1
        if ($Extraido) { Copy-Item "$($Extraido.FullName)\*" $DirectorioBase -Recurse -Force }
        Remove-Item "$env:TEMP\nginx_ftp" -Recurse -Force -ErrorAction SilentlyContinue
        $VersionElegida = "FTP"
    } else {
        $VersionElegida = Seleccionar-Version "nginx"
        if (-not $VersionElegida) { return }

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
            Expand-Archive -Path $ZipPath -DestinationPath "$env:TEMP\nginx_extract" -Force
            $Extraido = Get-ChildItem "$env:TEMP\nginx_extract" -Directory | Select-Object -First 1
            if ($Extraido) { Move-Item $Extraido.FullName $DirectorioBase }
            Remove-Item $ZipPath -Force
        } else {
            Write-Host "[*] Nginx ya instalado. Actualizando configuracion..." -ForegroundColor Cyan
        }
    }

    if (-not (Test-Path $NginxExe)) {
        Write-Host "[!] Error: nginx.exe no encontrado en $DirectorioBase" -ForegroundColor Red
        return
    }

    Write-Host "[*] Configurando puerto $Puerto y hardening..."
    $Contenido = Get-Content $ConfigNginx -Raw
    $Contenido = $Contenido -replace 'listen\s+\d+;', "listen       $Puerto;"
    if ($Contenido -notmatch "server_tokens off") {
        $Hardening = "    server_tokens off;`n    add_header X-Frame-Options SAMEORIGIN;`n    add_header X-Content-Type-Options nosniff;"
        $Contenido = $Contenido -replace '(http\s*\{)', "`$1`n$Hardening"
    }
    [System.IO.File]::WriteAllText($ConfigNginx, $Contenido, [System.Text.UTF8Encoding]::new($false))

    "<h1>Servidor: Nginx Win64 - Version: $VersionElegida - Puerto: $Puerto</h1>" | Out-File $RutaHtml -Encoding utf8

    $RuleName = "Nginx-Custom-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -LocalPort $Puerto -Protocol TCP -Action Allow | Out-Null
    }

    Write-Host "[*] Iniciando Nginx..."
    Start-Process -FilePath $NginxExe -WorkingDirectory $DirectorioBase -WindowStyle Hidden
    Start-Sleep -Seconds 2

    if (Get-Process -Name "nginx" -ErrorAction SilentlyContinue) {
        Write-Host "`n[OK] Nginx desplegado en puerto $Puerto." -ForegroundColor Green
    } else {
        Write-Host "`n[!] Nginx no inicio. Revisa: $DirectorioBase\logs\error.log" -ForegroundColor Red
    }

    $SSL = Read-Host "`nDesea activar SSL/TLS en Nginx? [S/N]"
    if ($SSL -match '^[Ss]$') {
        Configurar-SSL-Nginx -DirectorioBase $DirectorioBase -PuertoHTTP $Puerto
        Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
        Start-Process -FilePath $NginxExe -WorkingDirectory $DirectorioBase -WindowStyle Hidden
        Start-Sleep -Seconds 2
        if (Get-Process -Name "nginx" -ErrorAction SilentlyContinue) {
            Write-Host "[OK] Nginx reiniciado con SSL." -ForegroundColor Green
        } else {
            Write-Host "[!] Nginx no inicio con SSL. Revisa: $DirectorioBase\logs\error.log" -ForegroundColor Red
        }
    }
}

# ==========================================
# MODULO 3: APACHE WINDOWS
# ==========================================
Function Instalar-ApacheWin {
    param ([string]$Puerto)

    Write-Host "`n--- Iniciando aprovisionamiento de Apache (Win64) ---" -ForegroundColor Green

    $Origen = Obtener-Origen -Servicio "Apache"

    $HttpdExe = $null

    if ($Origen -eq '2') {
        $Binario = Obtener-Desde-FTP -Servicio "Apache"
        if (-not $Binario) { return }

        # Limpiar instalacion previa en Apache24_FTP
        if (Test-Path "C:\Apache24_FTP") {
            Remove-Item "C:\Apache24_FTP" -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host "[*] Extrayendo Apache desde FTP..."
        $ExtDir = "C:\Apache24_FTP"
        New-Item -Path $ExtDir -ItemType Directory | Out-Null
        if ($Binario -match "\.zip$") {
            Expand-Archive -Path $Binario -DestinationPath $ExtDir -Force
        } elseif ($Binario -match "\.(msi|exe)$") {
            Start-Process -FilePath $Binario -ArgumentList "/quiet" -Wait
        }

        Write-Host "[*] Buscando httpd.exe en instalacion FTP..."
        $HttpdExe = Get-ChildItem -Path "C:\Apache24_FTP" `
            -Recurse -Filter "httpd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

    } else {
        $VersionElegida = Seleccionar-Version "apache-httpd"
        if (-not $VersionElegida) { return }
        Write-Host "[*] Deteniendo IIS temporalmente para evitar conflicto de puerto..."
        $IISEstaba = (Get-Service W3SVC -ErrorAction SilentlyContinue).Status -eq "Running"
        if ($IISEstaba) { Stop-Service W3SVC -Force; Start-Sleep -Seconds 2 }

        Write-Host "[*] Instalando Apache via Chocolatey (Version: $VersionElegida)..."
        choco install apache-httpd --version $VersionElegida -y --force | Out-Null

        if ($IISEstaba) {
            Write-Host "[*] Reiniciando IIS..."
            Start-Service W3SVC
        }

        Write-Host "[*] Buscando httpd.exe en instalacion Chocolatey..."
        $HttpdExe = Get-ChildItem -Path "C:\tools","C:\ProgramData\chocolatey\lib","C:\Apache24","$env:APPDATA" `
            -Recurse -Filter "httpd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $HttpdExe) {
        Write-Host "[!] Error: No se encontro httpd.exe." -ForegroundColor Red
        return
    }

    $RutaApache   = $HttpdExe.DirectoryName | Split-Path -Parent
    $ConfigApache = "$RutaApache\conf\httpd.conf"
    $RutaHtml     = "$RutaApache\htdocs\index.html"

    Write-Host "[OK] Apache encontrado en: $RutaApache" -ForegroundColor Green

    Write-Host "[*] Configurando puerto $Puerto y hardening..."
    $Contenido = Get-Content $ConfigApache -Raw

    # Corregir ServerRoot y DocumentRoot si el zip tenia rutas hardcodeadas
    $RutaApacheSlash = $RutaApache -replace '\\', '/'
    $Contenido = $Contenido -replace 'ServerRoot "[^"]*"', "ServerRoot `"$RutaApacheSlash`""
    $Contenido = $Contenido -replace 'DocumentRoot "[^"]*"', "DocumentRoot `"$RutaApacheSlash/htdocs`""
    $Contenido = $Contenido -replace '<Directory "[^"]*htdocs">', "<Directory `"$RutaApacheSlash/htdocs`">"

    $Contenido = $Contenido -replace '(?m)^Listen\s+\d+', "Listen $Puerto"
    $Contenido = $Contenido -replace '(?m)^(LoadModule ssl_module)',            '#$1'
    $Contenido = $Contenido -replace '(?m)^(Include conf/extra/httpd-ssl.conf)','#$1'
    $Contenido = $Contenido -replace '(?m)^(LoadModule socache_shmcb_module)',  '#$1'
    if ($Contenido -match '(?m)^ServerTokens\s+\w+') {
        $Contenido = $Contenido -replace '(?m)^ServerTokens\s+\w+', "ServerTokens Prod"
    } else { $Contenido += "`nServerTokens Prod" }
    if ($Contenido -notmatch "ServerSignature") { $Contenido += "`nServerSignature Off" }
    $Contenido = $Contenido -replace '(?m)^#(LoadModule headers_module)', '$1'
    if ($Contenido -notmatch "X-Frame-Options") { $Contenido += "`nHeader always set X-Frame-Options `"SAMEORIGIN`"" }
    if ($Contenido -notmatch "X-Content-Type-Options") { $Contenido += "`nHeader always set X-Content-Type-Options `"nosniff`"" }
    [System.IO.File]::WriteAllText($ConfigApache, $Contenido, [System.Text.UTF8Encoding]::new($false))

    # Corregir rutas en httpd-ahssl.conf (SSL config de Apache Lounge)
    $AhSslConf = "$RutaApache\conf\extra\httpd-ahssl.conf"
    if (Test-Path $AhSslConf) {
        $ah = Get-Content $AhSslConf -Raw
        $ah = $ah -replace '\$\{SRVROOT\}/conf/ssl/server\.crt', "$RutaApacheSlash/conf/ssl/reprobados.crt"
        $ah = $ah -replace '\$\{SRVROOT\}/conf/ssl/server\.key', "$RutaApacheSlash/conf/ssl/reprobados.key"
        # Tambien corregir cualquier ruta hardcodeada a C:/Apache24
        $ah = $ah -replace 'C:/Apache24[^/]*/conf/ssl/server\.crt', "$RutaApacheSlash/conf/ssl/reprobados.crt"
        $ah = $ah -replace 'C:/Apache24[^/]*/conf/ssl/server\.key', "$RutaApacheSlash/conf/ssl/reprobados.key"
        [System.IO.File]::WriteAllText($AhSslConf, $ah, [System.Text.UTF8Encoding]::new($false))
    }

    "<h1>Servidor: Apache Win64 - Puerto: $Puerto</h1>" | Out-File $RutaHtml -Encoding utf8

    $RuleName = "Apache-Custom-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -LocalPort $Puerto -Protocol TCP -Action Allow | Out-Null
    }

    $ServicioExiste = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    if ($ServicioExiste) {
        Write-Host "[*] Desinstalando servicio Apache previo..."
        & "$RutaApache\bin\httpd.exe" -k uninstall | Out-Null
        Start-Sleep -Seconds 1
    }

    Write-Host "[*] Registrando e iniciando Apache..."
    & "$RutaApache\bin\httpd.exe" -k install | Out-Null
    Start-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $Srv = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    if ($Srv -and $Srv.Status -eq "Running") {
        Write-Host "`n[OK] Apache desplegado en puerto $Puerto." -ForegroundColor Green
    } else {
        Write-Host "`n[!] Apache no inicio. Revisa: $RutaApache\logs\error.log" -ForegroundColor Red
    }

    $SSL = Read-Host "`nDesea activar SSL/TLS en Apache? [S/N]"
    if ($SSL -match '^[Ss]$') {
        Configurar-SSL-Apache -RutaApache $RutaApache -PuertoHTTP $Puerto
        & "$RutaApache\bin\httpd.exe" -k restart | Out-Null
        Start-Sleep -Seconds 2
        $Srv = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
        if ($Srv -and $Srv.Status -eq "Running") {
            Write-Host "[OK] Apache reiniciado con SSL." -ForegroundColor Green
        } else {
            Write-Host "[!] Apache no inicio con SSL. Revisa: $RutaApache\logs\error.log" -ForegroundColor Red
        }
    }
}

# ==========================================
# MENU HTTP
# ==========================================
Function Menu-HTTP {
    do {
        Clear-Host
        Write-Host "=========================================================" -ForegroundColor Cyan
        Write-Host "   APROVISIONAMIENTO WEB AUTOMATIZADO - WINDOWS (P7)"     -ForegroundColor Cyan
        Write-Host "=========================================================" -ForegroundColor Cyan
        Write-Host "  1) Internet Information Services (IIS)"
        Write-Host "  2) Nginx (Win64)"
        Write-Host "  3) Apache (Win64)"
        Write-Host "  4) Ver resumen de servicios"
        Write-Host "  0) Regresar al Menu Principal"
        Write-Host "=========================================================" -ForegroundColor Cyan

        $Opcion = Read-Host "Ingrese una opcion"

        if ($Opcion -eq '0') { break }

        if ($Opcion -eq '4') {
            Mostrar-Resumen
            Pause
            continue
        }

        if ($Opcion -notin @('1','2','3')) {
            Write-Host "[!] Opcion no valida." -ForegroundColor Red
            Pause
            continue
        }

        $PuertoValido = $false
        $PuertoInput  = ""
        while (-not $PuertoValido) {
            $PuertoInput  = Read-Host "Ingrese el puerto de escucha deseado"
            $PuertoValido = Validar-Puerto -Puerto $PuertoInput
        }

        switch ($Opcion) {
            '1' { Instalar-IIS       -Puerto $PuertoInput }
            '2' { Instalar-Nginx     -Puerto $PuertoInput }
            '3' { Instalar-ApacheWin -Puerto $PuertoInput }
        }

        Mostrar-Resumen
        Pause

    } until ($false)
}