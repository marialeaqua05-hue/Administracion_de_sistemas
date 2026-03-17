#!/bin/bash
# Archivo: http.sh (Version AlmaLinux / RHEL - Practica 7)

# ==========================================
# CONFIGURACION GLOBAL
# ==========================================
FTP_IP="192.168.56.101"
FTP_USER="anonymous"
FTP_PASS=""
FTP_BASE="ftp://${FTP_IP}/http/Linux"
CERT_DNS="www.reprobados.com"
TEMP_DIR="/tmp/http_ftp"
SSL_DIR="/etc/pki/tls/reprobados"

# ==========================================
# VALIDACIONES
# ==========================================
validar_puerto() {
    local puerto=$1
    if [[ -z "$puerto" ]] || ! [[ "$puerto" =~ ^[0-9]+$ ]]; then
        echo "[!] Error: El puerto debe ser un valor numerico valido."
        return 1
    fi
    local puertos_reservados=(21 22 23 25 53 1433 3306 5432)
    for reservado in "${puertos_reservados[@]}"; do
        if [[ "$puerto" -eq "$reservado" ]]; then
            echo "[!] Error: El puerto $puerto esta reservado para otro servicio."
            return 1
        fi
    done
    if ss -tuln | grep -q ":$puerto "; then
        echo "[!] Error: El puerto $puerto ya esta ocupado por otro servicio activo."
        return 1
    fi
    return 0
}

seleccionar_version() {
    local paquete=$1
    echo "[*] Consultando repositorio (dnf) para: $paquete..." >&2
    mapfile -t versiones < <(dnf --showduplicates list "$paquete" --quiet 2>/dev/null | grep "^$paquete" | awk '{print $2}' | sort -u)
    if [ ${#versiones[@]} -eq 0 ]; then
        local version_unica
        version_unica=$(dnf info "$paquete" 2>/dev/null | grep "^Version" | awk '{print $3}')
        if [[ -n "$version_unica" ]]; then
            echo "[*] Unica version disponible: $version_unica" >&2
            echo "$version_unica"; return 0
        fi
        version_unica=$(rpm -q "$paquete" --queryformat "%{VERSION}-%{RELEASE}" 2>/dev/null)
        if [[ -n "$version_unica" ]]; then
            echo "[*] Version instalada: $version_unica" >&2
            echo "$version_unica"; return 0
        fi
        echo "[!] No se encontraron versiones." >&2; return 1
    fi
    if [ ${#versiones[@]} -eq 1 ]; then
        echo "[*] Unica version disponible: ${versiones[0]}" >&2
        echo "${versiones[0]}"; return 0
    fi
    echo "Versiones disponibles:" >&2
    for i in "${!versiones[@]}"; do
        echo "  $((i+1))) ${versiones[$i]}" >&2
    done
    local seleccion
    while true; do
        read -p "Seleccione el numero de la version a instalar: " seleccion
        if [[ "$seleccion" =~ ^[0-9]+$ ]] && [ "$seleccion" -ge 1 ] && [ "$seleccion" -le "${#versiones[@]}" ]; then
            echo "${versiones[$((seleccion-1))]}"; return 0
        else
            echo "[!] Seleccion invalida." >&2
        fi
    done
}

# ==========================================
# CERRAR PUERTOS POR DEFECTO
# ==========================================
cerrar_puertos_defecto() {
    local puerto_nuevo=$1
    local puertos_defecto=(80 8080 8443)
    echo "[*] Cerrando puertos por defecto no utilizados..."
    for p in "${puertos_defecto[@]}"; do
        if [[ "$puerto_nuevo" -ne "$p" ]]; then
            firewall-cmd --remove-port="$p/tcp" --permanent > /dev/null 2>&1
        fi
    done
    firewall-cmd --reload > /dev/null 2>&1
}

# ==========================================
# CREAR USUARIO DEDICADO
# ==========================================
crear_usuario_servicio() {
    local servicio=$1
    local directorio=$2
    if ! id "$servicio" &>/dev/null; then
        echo "[*] Creando usuario dedicado: $servicio..."
        useradd -r -s /sbin/nologin -d "$directorio" "$servicio"
    else
        echo "[*] Usuario $servicio ya existe."
    fi
    chown -R "$servicio":"$servicio" "$directorio"
    chmod 750 "$directorio"
    echo "[OK] Usuario $servicio configurado."
}

# ==========================================
# SELECCION DE ORIGEN (WEB o FTP)
# ==========================================
seleccionar_origen() {
    local servicio=$1
    echo "" >&2
    echo "Seleccione el origen de instalacion para $servicio:" >&2
    echo "  1) WEB (dnf / repositorio oficial)" >&2
    echo "  2) FTP (Repositorio Privado - $FTP_IP)" >&2
    read -p "Opcion: " origen < /dev/tty
    echo "$origen"
}

# ==========================================
# CLIENTE FTP DINAMICO (35% Rubrica)
# ==========================================
obtener_desde_ftp() {
    local servicio=$1
    local url_dir="${FTP_BASE}/${servicio}/"

    echo "[*] Conectando al repositorio FTP: $url_dir" >&2
    mkdir -p "$TEMP_DIR"

    # Listar archivos en el directorio del servicio
    local listado
    if [[ -n "$FTP_PASS" ]]; then
        listado=$(curl -s --list-only -u "${FTP_USER}:${FTP_PASS}" "$url_dir" 2>/dev/null)
    else
        listado=$(curl -s --list-only -u "${FTP_USER}:" "$url_dir" 2>/dev/null)
    fi

    if [[ -z "$listado" ]]; then
        echo "[!] Error: No se pudo conectar al FTP o el directorio esta vacio." >&2
        return 1
    fi

    # Filtrar solo binarios (excluir .sha256)
    mapfile -t archivos < <(echo "$listado" | grep -v "\.sha256$" | grep -E "\.(rpm|tar\.gz|tar\.bz2|zip)$" | sort)

    if [ ${#archivos[@]} -eq 0 ]; then
        echo "[!] No se encontraron binarios en FTP para $servicio." >&2
        return 1
    fi

    echo "Binarios disponibles en FTP ($servicio):" >&2
    for i in "${!archivos[@]}"; do
        echo "  $((i+1))) ${archivos[$i]}" >&2
    done

    local seleccion
    while true; do
        read -p "Seleccione el archivo a descargar: " seleccion < /dev/tty
        if [[ "$seleccion" =~ ^[0-9]+$ ]] && [ "$seleccion" -ge 1 ] && [ "$seleccion" -le "${#archivos[@]}" ]; then
            break
        fi
        echo "[!] Seleccion invalida."
    done

    local binario="${archivos[$((seleccion-1))]}"
    local url_bin="${url_dir}${binario}"
    local url_hash="${url_dir}${binario}.sha256"
    local dest_bin="${TEMP_DIR}/${binario}"
    local dest_hash="${TEMP_DIR}/${binario}.sha256"

    # Descargar binario
    echo "[*] Descargando $binario desde FTP..." >&2
    if [[ -n "$FTP_PASS" ]]; then
        curl -s -u "${FTP_USER}:${FTP_PASS}" "$url_bin" -o "$dest_bin"
    else
        curl -s -u "${FTP_USER}:" "$url_bin" -o "$dest_bin"
    fi

    if [[ ! -f "$dest_bin" ]] || [[ ! -s "$dest_bin" ]]; then
        echo "[!] Error al descargar el binario."
        return 1
    fi

    # Descargar hash
    echo "[*] Descargando archivo de integridad (.sha256)..." >&2
    if [[ -n "$FTP_PASS" ]]; then
        curl -s -u "${FTP_USER}:${FTP_PASS}" "$url_hash" -o "$dest_hash"
    else
        curl -s -u "${FTP_USER}:" "$url_hash" -o "$dest_hash"
    fi

    if [[ ! -f "$dest_hash" ]]; then
        echo "[!] Error al descargar el archivo .sha256."
        return 1
    fi

    # Validar integridad (15% Rubrica)
    echo "[*] Verificando integridad SHA256..." >&2
    local hash_calculado hash_esperado
    hash_calculado=$(sha256sum "$dest_bin" | awk '{print $1}')
    hash_esperado=$(awk '{print $1}' "$dest_hash")

    if [[ "$hash_calculado" == "$hash_esperado" ]]; then
        echo "[OK] Integridad validada: SHA256 coincide." >&2
        echo "$dest_bin"
        return 0
    else
        echo "[!] ERROR DE INTEGRIDAD: Hash no coincide." >&2
        echo "    Calculado : $hash_calculado" >&2
        echo "    Esperado  : $hash_esperado" >&2
        rm -f "$dest_bin"
        return 1
    fi
}

# ==========================================
# GENERACION DE CERTIFICADO SSL
# ==========================================
generar_certificado() {
    echo "[*] Generando certificado autofirmado para $CERT_DNS..."
    mkdir -p "$SSL_DIR"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_DIR/reprobados.key" \
        -out "$SSL_DIR/reprobados.crt" \
        -subj "/CN=$CERT_DNS/O=Reprobados/C=MX" 2>/dev/null
    chmod 600 "$SSL_DIR/reprobados.key"
    chmod 644 "$SSL_DIR/reprobados.crt"
    echo "[OK] Certificado generado en $SSL_DIR/"
}

# ==========================================
# SSL - APACHE
# ==========================================
configurar_ssl_apache() {
    local puerto_http=$1
    echo "[*] Configurando SSL/TLS en Apache (puerto 443)..."

    generar_certificado

    # Habilitar mod_ssl
    dnf install -yq mod_ssl 2>/dev/null

    # Crear VirtualHost SSL
    cat > /etc/httpd/conf.d/ssl_reprobados.conf << EOF
# SSL VirtualHost - Automatizado
# Listen 443 ya lo define mod_ssl, no se repite aqui

<VirtualHost *:443>
    ServerName $CERT_DNS
    SSLEngine on
    SSLCertificateFile    $SSL_DIR/reprobados.crt
    SSLCertificateKeyFile $SSL_DIR/reprobados.key
    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite        HIGH:!aNULL:!MD5
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff
    DocumentRoot /var/www/html
</VirtualHost>

# Redireccion HTTP -> HTTPS
<VirtualHost *:${puerto_http}>
    ServerName $CERT_DNS
    Redirect permanent / https://$CERT_DNS/
</VirtualHost>
EOF

    # SELinux para puerto 443
    semanage port -a -t http_port_t -p tcp 443 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp 443 2>/dev/null

    # Firewall
    firewall-cmd --add-port=443/tcp --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1

    systemctl restart httpd
    if systemctl is-active --quiet httpd; then
        echo "[OK] SSL/TLS activo en Apache puerto 443."
    else
        echo "[!] Apache no inicio con SSL. Revisa: journalctl -xeu httpd.service"
    fi
}

# ==========================================
# SSL - NGINX
# ==========================================
configurar_ssl_nginx() {
    local puerto_http=$1
    echo "[*] Configurando SSL/TLS en Nginx (puerto 8443)..."

    generar_certificado

    # Crear conf SSL
    cat > /etc/nginx/conf.d/ssl_reprobados.conf << EOF
# Redireccion HTTP -> HTTPS
server {
    listen $puerto_http;
    server_name $CERT_DNS;
    return 301 https://\$host:8443\$request_uri;
}

# HTTPS
server {
    listen 8443 ssl;
    server_name $CERT_DNS;

    ssl_certificate     $SSL_DIR/reprobados.crt;
    ssl_certificate_key $SSL_DIR/reprobados.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
    }
}
EOF

    # SELinux para puerto 8443
    semanage port -a -t http_port_t -p tcp 8443 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp 8443 2>/dev/null

    # Firewall
    firewall-cmd --add-port=8443/tcp --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1

    systemctl restart nginx
    if systemctl is-active --quiet nginx; then
        echo "[OK] SSL/TLS activo en Nginx puerto 8443."
    else
        echo "[!] Nginx no inicio con SSL. Revisa: journalctl -xeu nginx.service"
    fi
}

# ==========================================
# SSL - TOMCAT
# ==========================================
configurar_ssl_tomcat() {
    local puerto_http=$1
    echo "[*] Configurando SSL/TLS en Tomcat (puerto 8443)..."

    generar_certificado

    # Convertir certificado a formato PKCS12 para Tomcat
    local p12_file="/etc/tomcat/reprobados.p12"
    openssl pkcs12 -export \
        -in "$SSL_DIR/reprobados.crt" \
        -inkey "$SSL_DIR/reprobados.key" \
        -out "$p12_file" \
        -name reprobados \
        -passout pass:changeit 2>/dev/null
    chmod 640 "$p12_file"
    chown root:tomcat "$p12_file"

    # Agregar conector HTTPS en server.xml
    if ! grep -q "8443" /etc/tomcat/server.xml; then
        sed -i "/<\/Service>/i\\
    <Connector port=\"8443\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\"\\
               maxThreads=\"150\" SSLEnabled=\"true\" scheme=\"https\" secure=\"true\"\\
               keystoreFile=\"$p12_file\" keystorePass=\"changeit\" keystoreType=\"PKCS12\"\\
               clientAuth=\"false\" sslProtocol=\"TLS\"/>\\
" /etc/tomcat/server.xml
    fi

    # SELinux para puerto 8443
    semanage port -a -t http_port_t -p tcp 8443 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp 8443 2>/dev/null

    # Firewall
    firewall-cmd --add-port=8443/tcp --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1

    systemctl restart tomcat
    if systemctl is-active --quiet tomcat; then
        echo "[OK] SSL/TLS activo en Tomcat puerto 8443."
    else
        echo "[!] Tomcat no inicio con SSL. Revisa: journalctl -xeu tomcat.service"
    fi
}

# ==========================================
# RESUMEN AUTOMATIZADO
# ==========================================
mostrar_resumen() {
    echo ""
    echo "========================================================="
    echo "   RESUMEN DE VERIFICACION DE SERVICIOS HTTP"
    echo "========================================================="

    local servicios=("httpd:Apache:443" "nginx:Nginx:8443" "tomcat:Tomcat:8443")
    for entrada in "${servicios[@]}"; do
        local svc nombre puerto_ssl
        svc=$(echo "$entrada" | cut -d: -f1)
        nombre=$(echo "$entrada" | cut -d: -f2)
        puerto_ssl=$(echo "$entrada" | cut -d: -f3)

        local estado="DETENIDO"
        local ssl="NO"

        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            estado="ACTIVO"
        fi

        if ss -tlnp | grep -q ":$puerto_ssl "; then
            ssl="SI (puerto $puerto_ssl)"
        fi

        printf "  %-15s Estado: %-10s SSL: %s\n" "$nombre" "$estado" "$ssl"
    done

    echo "========================================================="

    if [[ -f "$SSL_DIR/reprobados.crt" ]]; then
        local expiry
        expiry=$(openssl x509 -in "$SSL_DIR/reprobados.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo "[OK] Certificado: CN=$CERT_DNS"
        echo "     Expira: $expiry"
    else
        echo "[!] No se encontro certificado para $CERT_DNS"
    fi
    echo ""
}

# ==========================================
# MODULOS DE INSTALACION
# ==========================================

instalar_apache() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Apache (httpd) ---"

    local origen
    origen=$(seleccionar_origen "Apache")
    local version_elegida=""

    if [[ "$origen" == "2" ]]; then
        local binario
        binario=$(obtener_desde_ftp "Apache")
        if [[ $? -ne 0 ]] || [[ -z "$binario" ]]; then return 1; fi

        echo "[*] Instalando Apache desde FTP: $binario..."
        if [[ "$binario" == *.rpm ]]; then
            dnf install -yq "$binario"
        elif [[ "$binario" == *.tar.gz ]]; then
            tar -xzf "$binario" -C /opt/
        fi
        version_elegida="FTP"
    else
        version_elegida=$(seleccionar_version "httpd")
        if [[ -z "$version_elegida" ]]; then return 1; fi
        echo "[*] Instalando silenciosamente (Version: $version_elegida)..."
        dnf install -yq "httpd-$version_elegida"
    fi

    echo "[*] Configurando puerto $puerto en httpd.conf..."
    sed -i "s/^Listen .*/Listen $puerto/g" /etc/httpd/conf/httpd.conf

    echo "[*] Aplicando Hardening de seguridad..."
    if ! grep -q "ServerTokens Prod" /etc/httpd/conf/httpd.conf; then
        cat >> /etc/httpd/conf/httpd.conf << EOF

# --- Reglas de Seguridad Automatizadas ---
ServerTokens Prod
ServerSignature Off
Header always set X-Frame-Options SAMEORIGIN
Header always set X-Content-Type-Options nosniff
EOF
    fi

    echo "[*] Bloqueando metodos HTTP peligrosos..."
    if ! grep -q "TraceEnable Off" /etc/httpd/conf/httpd.conf; then
        echo "TraceEnable Off" >> /etc/httpd/conf/httpd.conf
    fi
    if ! grep -q "LimitExcept" /etc/httpd/conf/httpd.conf; then
        sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/ {
            /<\/Directory>/ i\    <LimitExcept GET POST HEAD>\n        Require all denied\n    <\/LimitExcept>
        }' /etc/httpd/conf/httpd.conf
    fi

    echo "[*] Creando pagina web personalizada..."
    echo "<h1>Servidor: Apache - Version: $version_elegida - Puerto: $puerto</h1>" > /var/www/html/index.html

    if id "apache" &>/dev/null; then
        chown -R apache:apache /var/www/html
        chmod 750 /var/www/html
        echo "[OK] Usuario apache configurado."
    fi

    echo "[*] Configurando Firewall..."
    firewall-cmd --add-port="$puerto/tcp" --permanent > /dev/null 2>&1
    cerrar_puertos_defecto "$puerto"

    echo "[*] Autorizando puerto $puerto en SELinux..."
    semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null

    echo "[*] Iniciando servicio..."
    systemctl enable httpd > /dev/null 2>&1
    systemctl restart httpd

    if systemctl is-active --quiet httpd; then
        echo -e "\n[OK] Apache desplegado en el puerto $puerto."
    else
        echo -e "\n[!] Apache no inicio. Revisa: journalctl -xeu httpd.service"
        return 1
    fi

    read -p $'\n¿Desea activar SSL/TLS en Apache? [S/N]: ' ssl
    if [[ "$ssl" =~ ^[Ss]$ ]]; then
        configurar_ssl_apache "$puerto"
    fi
}

instalar_nginx() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Nginx ---"

    local origen
    origen=$(seleccionar_origen "Nginx")
    local version_elegida=""

    if [[ "$origen" == "2" ]]; then
        local binario
        binario=$(obtener_desde_ftp "Nginx")
        if [[ $? -ne 0 ]] || [[ -z "$binario" ]]; then return 1; fi

        echo "[*] Instalando Nginx desde FTP: $binario..."
        if [[ "$binario" == *.rpm ]]; then
            dnf install -yq "$binario"
        fi
        version_elegida="FTP"
    else
        version_elegida=$(seleccionar_version "nginx")
        if [[ -z "$version_elegida" ]]; then return 1; fi
        echo "[*] Instalando silenciosamente (Version: $version_elegida)..."
        dnf install -yq "nginx-$version_elegida"
    fi

    echo "[*] Configurando puerto $puerto en nginx.conf..."
    sed -i -E "s/listen\s+[0-9]+\s*;/listen       $puerto;/g" /etc/nginx/nginx.conf
    sed -i -E "s/listen\s+\[::\]:[0-9]+\s*;/listen       [::]:$puerto;/g" /etc/nginx/nginx.conf

    echo "[*] Aplicando Hardening..."
    if ! grep -q "server_tokens off;" /etc/nginx/nginx.conf; then
        sed -i '/http {/a \    server_tokens off;\n    add_header X-Frame-Options SAMEORIGIN;\n    add_header X-Content-Type-Options nosniff;' /etc/nginx/nginx.conf
    fi

    # Bloqueo de metodos - insertar dentro del primer bloque location /
    if ! grep -q "request_method" /etc/nginx/nginx.conf; then
        sed -i '/location \/ {/a \            if ($request_method !~ ^(GET|POST|HEAD)$) {\n                return 405;\n            }' /etc/nginx/nginx.conf
    fi

    echo "<h1>Servidor: Nginx - Version: $version_elegida - Puerto: $puerto</h1>" > /usr/share/nginx/html/index.html
    crear_usuario_servicio "nginx" "/usr/share/nginx/html"

    echo "[*] Configurando Firewall..."
    firewall-cmd --add-port="$puerto/tcp" --permanent > /dev/null 2>&1
    cerrar_puertos_defecto "$puerto"

    echo "[*] Autorizando puerto $puerto en SELinux..."
    semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null

    echo "[*] Iniciando servicio..."
    systemctl enable nginx > /dev/null 2>&1
    systemctl restart nginx

    if systemctl is-active --quiet nginx; then
        echo -e "\n[OK] Nginx desplegado en el puerto $puerto."
    else
        echo -e "\n[!] Nginx no inicio. Revisa: journalctl -xeu nginx.service"
        return 1
    fi

    read -p $'\n¿Desea activar SSL/TLS en Nginx? [S/N]: ' ssl
    if [[ "$ssl" =~ ^[Ss]$ ]]; then
        configurar_ssl_nginx "$puerto"
    fi
}

instalar_tomcat() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Tomcat ---"

    local origen
    origen=$(seleccionar_origen "Tomcat")
    local version_elegida=""

    if [[ "$origen" == "2" ]]; then
        local binario
        binario=$(obtener_desde_ftp "Tomcat")
        if [[ $? -ne 0 ]] || [[ -z "$binario" ]]; then return 1; fi

        echo "[*] Instalando Tomcat desde FTP: $binario..."
        if [[ "$binario" == *.rpm ]]; then
            dnf install -yq "$binario"
        fi
        version_elegida="FTP"
    else
        version_elegida=$(seleccionar_version "tomcat")
        if [[ -z "$version_elegida" ]]; then return 1; fi
        echo "[*] Instalando silenciosamente (Version: $version_elegida)..."
        dnf install -yq "tomcat-$version_elegida" tomcat-webapps tomcat-admin-webapps
    fi

    echo "[*] Configurando puerto $puerto en server.xml..."
    sed -i "s/port=\"8080\"/port=\"$puerto\"/g" /etc/tomcat/server.xml

    echo "[*] Aplicando Hardening..."
    if ! grep -q "ErrorReportValve" /etc/tomcat/server.xml; then
        sed -i 's/<Host name="localhost"  appBase="webapps"/<Host name="localhost"  appBase="webapps">\n        <Valve className="org.apache.catalina.valves.ErrorReportValve" showReport="false" showServerInfo="false" \/>/' /etc/tomcat/server.xml
    fi
    if ! grep -q 'server="AppServer"' /etc/tomcat/server.xml; then
        sed -i 's/protocol="HTTP\/1.1"/protocol="HTTP\/1.1" server="AppServer"/g' /etc/tomcat/server.xml
    fi

    local WEBXML="/etc/tomcat/web.xml"
    if [[ -f "$WEBXML" ]] && ! grep -q "TRACE" "$WEBXML"; then
        sed -i 's|</web-app>|<security-constraint>\n<web-resource-collection>\n<web-resource-name>Restricted Methods</web-resource-name>\n<url-pattern>/*</url-pattern>\n<http-method>TRACE</http-method>\n<http-method>TRACK</http-method>\n<http-method>DELETE</http-method>\n</web-resource-collection>\n<auth-constraint/>\n</security-constraint>\n</web-app>|' "$WEBXML"
    fi

    crear_usuario_servicio "tomcat" "/var/lib/tomcat/webapps"

    echo "[*] Configurando Firewall..."
    firewall-cmd --add-port="$puerto/tcp" --permanent > /dev/null 2>&1
    cerrar_puertos_defecto "$puerto"

    echo "[*] Autorizando puerto $puerto en SELinux..."
    semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null

    echo "[*] Iniciando servicio..."
    systemctl enable tomcat > /dev/null 2>&1
    systemctl restart tomcat

    if systemctl is-active --quiet tomcat; then
        echo -e "\n[OK] Tomcat desplegado en el puerto $puerto."
    else
        echo -e "\n[!] Tomcat no inicio. Revisa: journalctl -xeu tomcat.service"
        return 1
    fi

    read -p $'\n¿Desea activar SSL/TLS en Tomcat? [S/N]: ' ssl
    if [[ "$ssl" =~ ^[Ss]$ ]]; then
        configurar_ssl_tomcat "$puerto"
    fi
}

# ==========================================
# CAMBIAR PUERTO DE SERVICIO EXISTENTE
# ==========================================
cambiar_puerto() {
    echo -e "\n--- Cambiar Puerto de Servicio HTTP ---"
    echo "  1) Apache (httpd)"
    echo "  2) Nginx"
    echo "  3) Tomcat"
    read -p "Seleccione el servicio: " servicio

    if [[ ! "$servicio" =~ ^[1-3]$ ]]; then
        echo "[!] Opcion invalida."; return 1
    fi

    local puerto_input
    while true; do
        read -p "Ingrese el nuevo puerto de escucha: " puerto_input
        if validar_puerto "$puerto_input"; then break; fi
    done

    case $servicio in
        1)
            if ! systemctl is-active --quiet httpd; then
                echo "[!] Apache no esta corriendo."; return 1
            fi
            sed -i "s/^Listen .*/Listen $puerto_input/g" /etc/httpd/conf/httpd.conf
            puerto_anterior=$(ss -tlnp | grep httpd | awk '{print $4}' | cut -d: -f2 | head -1)
            [[ -n "$puerto_anterior" ]] && firewall-cmd --remove-port="$puerto_anterior/tcp" --permanent > /dev/null 2>&1
            firewall-cmd --add-port="$puerto_input/tcp" --permanent > /dev/null 2>&1
            cerrar_puertos_defecto "$puerto_input"
            sed -i "s/Puerto: [0-9]*/Puerto: $puerto_input/" /var/www/html/index.html
            semanage port -a -t http_port_t -p tcp "$puerto_input" 2>/dev/null || \
            semanage port -m -t http_port_t -p tcp "$puerto_input" 2>/dev/null
            systemctl restart httpd
            systemctl is-active --quiet httpd && echo "[OK] Puerto Apache cambiado a $puerto_input." || echo "[!] Apache no inicio."
            ;;
        2)
            if ! systemctl is-active --quiet nginx; then
                echo "[!] Nginx no esta corriendo."; return 1
            fi
            sed -i -E "s/listen\s+[0-9]+\s*;/listen       $puerto_input;/g" /etc/nginx/nginx.conf
            sed -i -E "s/listen\s+\[::\]:[0-9]+\s*;/listen       [::]:$puerto_input;/g" /etc/nginx/nginx.conf
            puerto_anterior=$(ss -tlnp | grep nginx | awk '{print $4}' | cut -d: -f2 | head -1)
            [[ -n "$puerto_anterior" ]] && firewall-cmd --remove-port="$puerto_anterior/tcp" --permanent > /dev/null 2>&1
            firewall-cmd --add-port="$puerto_input/tcp" --permanent > /dev/null 2>&1
            cerrar_puertos_defecto "$puerto_input"
            sed -i "s/Puerto: [0-9]*/Puerto: $puerto_input/" /usr/share/nginx/html/index.html
            semanage port -a -t http_port_t -p tcp "$puerto_input" 2>/dev/null || \
            semanage port -m -t http_port_t -p tcp "$puerto_input" 2>/dev/null
            systemctl restart nginx
            systemctl is-active --quiet nginx && echo "[OK] Puerto Nginx cambiado a $puerto_input." || echo "[!] Nginx no inicio."
            ;;
        3)
            if ! systemctl is-active --quiet tomcat; then
                echo "[!] Tomcat no esta corriendo."; return 1
            fi
            puerto_anterior=$(grep -oP 'port="\K[0-9]+' /etc/tomcat/server.xml | head -1)
            sed -i "s/port=\"$puerto_anterior\"/port=\"$puerto_input\"/g" /etc/tomcat/server.xml
            [[ -n "$puerto_anterior" ]] && firewall-cmd --remove-port="$puerto_anterior/tcp" --permanent > /dev/null 2>&1
            firewall-cmd --add-port="$puerto_input/tcp" --permanent > /dev/null 2>&1
            cerrar_puertos_defecto "$puerto_input"
            semanage port -a -t http_port_t -p tcp "$puerto_input" 2>/dev/null || \
            semanage port -m -t http_port_t -p tcp "$puerto_input" 2>/dev/null
            systemctl restart tomcat
            systemctl is-active --quiet tomcat && echo "[OK] Puerto Tomcat cambiado a $puerto_input." || echo "[!] Tomcat no inicio."
            ;;
    esac
}

# ==========================================
# MENU HTTP
# ==========================================
function menu_http() {
    while true; do
        clear
        echo "========================================================="
        echo "   APROVISIONAMIENTO WEB AUTOMATIZADO - ALMALINUX (P7)"
        echo "========================================================="
        echo "  1) Apache (httpd)"
        echo "  2) Nginx"
        echo "  3) Tomcat"
        echo "  4) Cambiar puerto de servicio existente"
        echo "  5) Ver resumen de servicios"
        echo "  0) Regresar al Menu Principal"
        echo "========================================================="
        read -p "Ingrese una opcion: " opcion

        if [[ "$opcion" == "0" ]]; then break; fi

        if [[ "$opcion" == "4" ]]; then
            cambiar_puerto
            read -p "Presione Enter para continuar..."
            continue
        fi

        if [[ "$opcion" == "5" ]]; then
            mostrar_resumen
            read -p "Presione Enter para continuar..."
            continue
        fi

        if [[ ! "$opcion" =~ ^[1-3]$ ]]; then
            echo "[!] Error: Opcion no valida."
            read -p "Presione Enter para continuar..."
            continue
        fi

        local puerto_input
        while true; do
            read -p "Ingrese el puerto de escucha deseado (ej. 80, 8080): " puerto_input
            if validar_puerto "$puerto_input"; then break; fi
        done

        case $opcion in
            1) instalar_apache "$puerto_input" ;;
            2) instalar_nginx "$puerto_input" ;;
            3) instalar_tomcat "$puerto_input" ;;
        esac

        mostrar_resumen
        read -p "Presione Enter para continuar..."
    done
}