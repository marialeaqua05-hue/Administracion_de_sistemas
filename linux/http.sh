#!/bin/bash
# Archivo: http.sh (Version AlmaLinux / RHEL)

# ==========================================
# VALIDACIONES
# ==========================================

validar_puerto() {
    local puerto=$1
    if [[ -z "$puerto" ]] || ! [[ "$puerto" =~ ^[0-9]+$ ]]; then
        echo "[!] Error: El puerto debe ser un valor numerico valido."
        return 1
    fi

    local puertos_reservados=(21 22 23 25 53 443 1433 3306 5432 8443)
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
            echo "[*] Unica version disponible en repositorio: $version_unica" >&2
            echo "$version_unica"
            return 0
        fi
        version_unica=$(rpm -q "$paquete" --queryformat "%{VERSION}-%{RELEASE}" 2>/dev/null)
        if [[ -n "$version_unica" ]]; then
            echo "[*] Unica version disponible (instalada): $version_unica" >&2
            echo "$version_unica"
            return 0
        fi
        echo "[!] No se encontraron versiones en el repositorio." >&2
        return 1
    fi

    if [ ${#versiones[@]} -eq 1 ]; then
        echo "[*] Unica version disponible: ${versiones[0]}" >&2
        echo "${versiones[0]}"
        return 0
    fi

    echo "Versiones disponibles:" >&2
    for i in "${!versiones[@]}"; do
        echo "  $((i+1))) ${versiones[$i]}" >&2
    done

    local seleccion
    while true; do
        read -p "Seleccione el numero de la version a instalar: " seleccion
        if [[ "$seleccion" =~ ^[0-9]+$ ]] && [ "$seleccion" -ge 1 ] && [ "$seleccion" -le "${#versiones[@]}" ]; then
            echo "${versiones[$((seleccion-1))]}"
            return 0
        else
            echo "[!] Seleccion invalida. Intente de nuevo." >&2
        fi
    done
}

# ==========================================
# CERRAR PUERTOS POR DEFECTO NO UTILIZADOS
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
# CREAR USUARIO DEDICADO PARA SERVICIO WEB
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

    echo "[*] Aplicando permisos restrictivos a $directorio..."
    chown -R "$servicio":"$servicio" "$directorio"
    chmod 750 "$directorio"
    echo "[OK] Usuario $servicio configurado con permisos limitados a $directorio."
}

# ==========================================
# MODULOS DE INSTALACION
# ==========================================

instalar_apache() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Apache (httpd) ---"

    local version_elegida
    version_elegida=$(seleccionar_version "httpd")
    if [ -z "$version_elegida" ]; then return 1; fi

    echo "[*] Instalando silenciosamente (Version: $version_elegida)..."
    dnf install -yq "httpd-$version_elegida"

    echo "[*] Configurando puerto $puerto en httpd.conf..."
    sed -i "s/^Listen .*/Listen $puerto/g" /etc/httpd/conf/httpd.conf

    echo "[*] Aplicando Hardening de seguridad..."
    if ! grep -q "ServerTokens Prod" /etc/httpd/conf/httpd.conf; then
        cat >> /etc/httpd/conf/httpd.conf <<EOF

# --- Reglas de Seguridad Automatizadas ---
ServerTokens Prod
ServerSignature Off
Header always set X-Frame-Options SAMEORIGIN
Header always set X-Content-Type-Options nosniff
EOF
    fi

    echo "[*] Bloqueando metodos HTTP peligrosos (TRACE, TRACK, DELETE)..."
    # TraceEnable va a nivel global (fuera de Directory)
    if ! grep -q "TraceEnable Off" /etc/httpd/conf/httpd.conf; then
        echo "TraceEnable Off" >> /etc/httpd/conf/httpd.conf
    fi
    # LimitExcept debe ir dentro de un bloque Directory
    if ! grep -q "LimitExcept" /etc/httpd/conf/httpd.conf; then
        sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/ {
            /<\/Directory>/ i\    <LimitExcept GET POST HEAD>\n        Require all denied\n    <\/LimitExcept>
        }' /etc/httpd/conf/httpd.conf
    fi

    echo "[*] Creando pagina web personalizada..."
    echo "<h1>Servidor: Apache - Version: $version_elegida - Puerto: $puerto</h1>" > /var/www/html/index.html

    echo "[*] Verificando usuario dedicado apache..."
    if id "apache" &>/dev/null; then
        chown -R apache:apache /var/www/html
        chmod 750 /var/www/html
        echo "[OK] Usuario apache con permisos limitados a /var/www/html."
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
        echo -e "\n[OK] Apache desplegado y asegurado con exito en el puerto $puerto."
    else
        echo -e "\n[!] Apache no inicio correctamente. Revisa: journalctl -xeu httpd.service"
    fi
}

instalar_nginx() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Nginx ---"

    local version_elegida
    version_elegida=$(seleccionar_version "nginx")
    if [ -z "$version_elegida" ]; then return 1; fi

    echo "[*] Instalando silenciosamente (Version: $version_elegida)..."
    dnf install -yq "nginx-$version_elegida"

    echo "[*] Configurando puerto $puerto en nginx.conf..."
    sed -i -E "s/listen\s+[0-9]+\s*;/listen       $puerto;/g" /etc/nginx/nginx.conf
    sed -i -E "s/listen\s+\[::\]:[0-9]+\s*;/listen       [::]:$puerto;/g" /etc/nginx/nginx.conf

    echo "[*] Aplicando Hardening de seguridad..."
    if ! grep -q "server_tokens off;" /etc/nginx/nginx.conf; then
        sed -i '/http {/a \    server_tokens off;\n    add_header X-Frame-Options SAMEORIGIN;\n    add_header X-Content-Type-Options nosniff;' /etc/nginx/nginx.conf
    fi

    echo "[*] Bloqueando metodos HTTP peligrosos (TRACE, TRACK, DELETE)..."
    if ! grep -q "limit_except" /etc/nginx/nginx.conf; then
        sed -i '/server {/a \        if ($request_method !~ ^(GET|POST|HEAD)$) {\n            return 405;\n        }' /etc/nginx/nginx.conf
    fi

    echo "[*] Creando pagina web personalizada..."
    echo "<h1>Servidor: Nginx - Version: $version_elegida - Puerto: $puerto</h1>" > /usr/share/nginx/html/index.html

    echo "[*] Configurando usuario dedicado nginx..."
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
        echo -e "\n[OK] Nginx desplegado y asegurado con exito en el puerto $puerto."
    else
        echo -e "\n[!] Nginx no inicio correctamente. Revisa: journalctl -xeu nginx.service"
    fi
}

instalar_tomcat() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Tomcat ---"

    local version_elegida
    version_elegida=$(seleccionar_version "tomcat")
    if [ -z "$version_elegida" ]; then return 1; fi

    echo "[*] Instalando silenciosamente Tomcat y dependencias Java (Version: $version_elegida)..."
    dnf install -yq "tomcat-$version_elegida" tomcat-webapps tomcat-admin-webapps

    echo "[*] Configurando puerto $puerto en server.xml..."
    sed -i "s/port=\"8080\"/port=\"$puerto\"/g" /etc/tomcat/server.xml

    echo "[*] Aplicando Hardening de seguridad..."
    if ! grep -q "ErrorReportValve" /etc/tomcat/server.xml; then
        sed -i 's/<Host name="localhost"  appBase="webapps"/<Host name="localhost"  appBase="webapps">\n        <Valve className="org.apache.catalina.valves.ErrorReportValve" showReport="false" showServerInfo="false" \/>/' /etc/tomcat/server.xml
    fi
    if ! grep -q 'server="AppServer"' /etc/tomcat/server.xml; then
        sed -i 's/protocol="HTTP\/1.1"/protocol="HTTP\/1.1" server="AppServer"/g' /etc/tomcat/server.xml
    fi

    echo "[*] Bloqueando metodos HTTP peligrosos en Tomcat (web.xml)..."
    local WEBXML="/etc/tomcat/web.xml"
    if [[ -f "$WEBXML" ]] && ! grep -q "TRACE" "$WEBXML"; then
        sed -i 's|</web-app>|<security-constraint>\n<web-resource-collection>\n<web-resource-name>Restricted Methods</web-resource-name>\n<url-pattern>/*</url-pattern>\n<http-method>TRACE</http-method>\n<http-method>TRACK</http-method>\n<http-method>DELETE</http-method>\n</web-resource-collection>\n<auth-constraint/>\n</security-constraint>\n</web-app>|' "$WEBXML"
    fi

    echo "[*] Configurando usuario dedicado tomcat..."
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
        echo -e "\n[OK] Tomcat desplegado y asegurado con exito en el puerto $puerto."
    else
        echo -e "\n[!] Tomcat no inicio correctamente. Revisa: journalctl -xeu tomcat.service"
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
        echo "[!] Opcion invalida."
        return 1
    fi

    local puerto_input
    while true; do
        read -p "Ingrese el nuevo puerto de escucha: " puerto_input
        if validar_puerto "$puerto_input"; then break; fi
    done

    case $servicio in
        1)
            if ! systemctl is-active --quiet httpd; then
                echo "[!] Apache no esta instalado o no esta corriendo."
                return 1
            fi
            echo "[*] Cambiando puerto de Apache a $puerto_input..."
            sed -i "s/^Listen .*/Listen $puerto_input/g" /etc/httpd/conf/httpd.conf
            puerto_anterior=$(ss -tlnp | grep httpd | awk '{print $4}' | cut -d: -f2 | head -1)
            if [[ -n "$puerto_anterior" ]]; then
                firewall-cmd --remove-port="$puerto_anterior/tcp" --permanent > /dev/null 2>&1
            fi
            firewall-cmd --add-port="$puerto_input/tcp" --permanent > /dev/null 2>&1
            cerrar_puertos_defecto "$puerto_input"
            sed -i "s/Puerto: [0-9]*/Puerto: $puerto_input/" /var/www/html/index.html
            echo "[*] Autorizando puerto $puerto_input en SELinux..."
            semanage port -a -t http_port_t -p tcp "$puerto_input" 2>/dev/null || \
            semanage port -m -t http_port_t -p tcp "$puerto_input" 2>/dev/null
            systemctl restart httpd
            if systemctl is-active --quiet httpd; then
                echo "[OK] Puerto de Apache cambiado a $puerto_input."
            else
                echo "[!] Apache no inicio. Revisa: journalctl -xeu httpd.service"
            fi
            ;;
        2)
            if ! systemctl is-active --quiet nginx; then
                echo "[!] Nginx no esta instalado o no esta corriendo."
                return 1
            fi
            echo "[*] Cambiando puerto de Nginx a $puerto_input..."
            sed -i -E "s/listen\s+[0-9]+\s*;/listen       $puerto_input;/g" /etc/nginx/nginx.conf
            sed -i -E "s/listen\s+\[::\]:[0-9]+\s*;/listen       [::]:$puerto_input;/g" /etc/nginx/nginx.conf
            puerto_anterior=$(ss -tlnp | grep nginx | awk '{print $4}' | cut -d: -f2 | head -1)
            if [[ -n "$puerto_anterior" ]]; then
                firewall-cmd --remove-port="$puerto_anterior/tcp" --permanent > /dev/null 2>&1
            fi
            firewall-cmd --add-port="$puerto_input/tcp" --permanent > /dev/null 2>&1
            cerrar_puertos_defecto "$puerto_input"
            sed -i "s/Puerto: [0-9]*/Puerto: $puerto_input/" /usr/share/nginx/html/index.html
            echo "[*] Autorizando puerto $puerto_input en SELinux..."
            semanage port -a -t http_port_t -p tcp "$puerto_input" 2>/dev/null || \
            semanage port -m -t http_port_t -p tcp "$puerto_input" 2>/dev/null
            systemctl restart nginx
            if systemctl is-active --quiet nginx; then
                echo "[OK] Puerto de Nginx cambiado a $puerto_input."
            else
                echo "[!] Nginx no inicio. Revisa: journalctl -xeu nginx.service"
            fi
            ;;
        3)
            if ! systemctl is-active --quiet tomcat; then
                echo "[!] Tomcat no esta instalado o no esta corriendo."
                return 1
            fi
            echo "[*] Cambiando puerto de Tomcat a $puerto_input..."
            puerto_anterior=$(grep -oP 'port="\K[0-9]+' /etc/tomcat/server.xml | head -1)
            sed -i "s/port=\"$puerto_anterior\"/port=\"$puerto_input\"/g" /etc/tomcat/server.xml
            if [[ -n "$puerto_anterior" ]]; then
                firewall-cmd --remove-port="$puerto_anterior/tcp" --permanent > /dev/null 2>&1
            fi
            firewall-cmd --add-port="$puerto_input/tcp" --permanent > /dev/null 2>&1
            cerrar_puertos_defecto "$puerto_input"
            echo "[*] Autorizando puerto $puerto_input en SELinux..."
            semanage port -a -t http_port_t -p tcp "$puerto_input" 2>/dev/null || \
            semanage port -m -t http_port_t -p tcp "$puerto_input" 2>/dev/null
            systemctl restart tomcat
            if systemctl is-active --quiet tomcat; then
                echo "[OK] Puerto de Tomcat cambiado a $puerto_input."
            else
                echo "[!] Tomcat no inicio. Revisa: journalctl -xeu tomcat.service"
            fi
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
        echo "      APROVISIONAMIENTO WEB AUTOMATIZADO (ALMALINUX)"
        echo "========================================================="
        echo " Seleccione el servicio HTTP a desplegar:"
        echo "  1) Apache (httpd)"
        echo "  2) Nginx"
        echo "  3) Tomcat"
        echo "  4) Cambiar puerto de servicio existente"
        echo "  0) Regresar al Menu Principal"
        echo "========================================================="
        read -p "Ingrese una opcion: " opcion

        if [[ "$opcion" == "0" ]]; then break; fi
        if [[ ! "$opcion" =~ ^[1-4]$ ]]; then
            echo "[!] Error: Opcion no valida."
            read -p "Presione Enter para continuar..."
            continue
        fi

        if [[ "$opcion" == "4" ]]; then
            cambiar_puerto
        else
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
        fi

        echo ""
        read -p "Presione Enter para continuar..."
    done
}