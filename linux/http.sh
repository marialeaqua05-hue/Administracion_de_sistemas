#!/bin/bash
# Archivo: http.sh (Versión AlmaLinux / RHEL)

# VALIDACIONES

validar_puerto() {
    local puerto=$1
    if [[ -z "$puerto" ]] || ! [[ "$puerto" =~ ^[0-9]+$ ]]; then
        echo "[!] Error: El puerto debe ser un valor numérico válido."
        return 1
    fi

    # NUEVO: Lista negra de puertos reservados (SSH, DNS, HTTPS, SQL, MySQL, etc.)
    local puertos_reservados=(21 22 23 25 53 443 1433 3306 5432 8443)
    for reservado in "${puertos_reservados[@]}"; do
        if [[ "$puerto" -eq "$reservado" ]]; then
            echo "[!] Error: El puerto $puerto está reservado históricamente para otro servicio."
            return 1
        fi
    done
    
    # Verificación de puertos ocupados actualmente en memoria
    if ss -tuln | grep -q ":$puerto "; then
        echo "[!] Error: El puerto $puerto ya está ocupado por otro servicio activo."
        return 1
    fi
    return 0
}

seleccionar_version() {
    local paquete=$1
    echo "[*] Consultando repositorio (dnf) para: $paquete..." >&2
    
    # Extrae versiones reales en AlmaLinux/RHEL
    mapfile -t versiones < <(dnf --showduplicates list "$paquete" --quiet 2>/dev/null | grep "^$paquete" | awk '{print $2}' | sort -u)
    
    if [ ${#versiones[@]} -eq 0 ]; then
        echo "[!] No se encontraron versiones en el repositorio." >&2
        return 1
    fi

    echo "Versiones disponibles:" >&2
    for i in "${!versiones[@]}"; do
        echo "  $((i+1))) ${versiones[$i]}" >&2
    done

    local seleccion
    while true; do
        read -p "Seleccione el número de la versión a instalar: " seleccion
        if [[ "$seleccion" =~ ^[0-9]+$ ]] && [ "$seleccion" -ge 1 ] && [ "$seleccion" -le "${#versiones[@]}" ]; then
            local indice=$((seleccion-1))
            
            # ESTE ES EL ÚNICO ECHO SIN >&2 (Para que se guarde en la variable)
            echo "${versiones[$indice]}"
            return 0
        else
            echo "[!] Selección inválida. Intente de nuevo." >&2
        fi
    done
}

# MÓDULOS DE INSTALACIÓN

instalar_apache() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Apache (httpd) ---"
    
    # En AlmaLinux, Apache se llama 'httpd'
    local version_elegida
    version_elegida=$(seleccionar_version "httpd")
    if [ -z "$version_elegida" ]; then return 1; fi
    
    echo "[*] Instalando silenciosamente (Versión: $version_elegida)..."
    dnf install -yq "httpd-$version_elegida"
    
    echo "[*] Configurando puerto $puerto en httpd.conf..."
    # Cambia el puerto de escucha
    sed -i "s/^Listen .*/Listen $puerto/g" /etc/httpd/conf/httpd.conf
    
    echo "[*] Aplicando Hardening (Seguridad) exigido por la rúbrica..."
    # Insertar reglas de seguridad al final del archivo si no existen
    if ! grep -q "ServerTokens Prod" /etc/httpd/conf/httpd.conf; then
        echo -e "\n# --- Reglas de Seguridad Automatizadas ---" >> /etc/httpd/conf/httpd.conf
        echo "ServerTokens Prod" >> /etc/httpd/conf/httpd.conf
        echo "ServerSignature Off" >> /etc/httpd/conf/httpd.conf
        echo "Header always set X-Frame-Options SAMEORIGIN" >> /etc/httpd/conf/httpd.conf
        echo "Header always set X-Content-Type-Options nosniff" >> /etc/httpd/conf/httpd.conf
    fi
    
    echo "[*] Creando página web personalizada..."
    # Crear el index html con la frase requerida
    echo "<h1>Servidor: Apache - Versión: $version_elegida - Puerto: $puerto</h1>" > /var/www/html/index.html
    
    echo "[*] Configurando Firewall (firewalld)..."
    firewall-cmd --add-port="$puerto/tcp" --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    
    echo "[*] Reiniciando servicio para aplicar cambios..."
    systemctl enable httpd > /dev/null 2>&1
    systemctl restart httpd
    
    echo -e "\n[OK] Apache desplegado y asegurado con éxito en el puerto $puerto."
}

instalar_nginx() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Nginx ---"
    
    local version_elegida
    version_elegida=$(seleccionar_version "nginx")
    if [ -z "$version_elegida" ]; then return 1; fi
    
    echo "[*] Instalando silenciosamente (Versión: $version_elegida)..."
    dnf install -yq "nginx-$version_elegida"
    
    echo "[*] Configurando puerto $puerto en nginx.conf..."
    # Cambia el puerto en la configuración por defecto de Nginx usando expresiones regulares
    sed -i -E "s/listen\s+[0-9]+\s*;/listen       $puerto;/g" /etc/nginx/nginx.conf
    sed -i -E "s/listen\s+\[::\]:[0-9]+\s*;/listen       [::]:$puerto;/g" /etc/nginx/nginx.conf
    
    echo "[*] Aplicando Hardening (Seguridad) exigido por la rúbrica..."
    # Inyectar seguridad globalmente dentro del bloque http {
    if ! grep -q "server_tokens off;" /etc/nginx/nginx.conf; then
        sed -i '/http {/a \    server_tokens off;\n    add_header X-Frame-Options SAMEORIGIN;\n    add_header X-Content-Type-Options nosniff;' /etc/nginx/nginx.conf
    fi
    
    echo "[*] Creando página web personalizada..."
    # Nginx en AlmaLinux guarda su html en /usr/share/nginx/html
    echo "<h1>Servidor: Nginx - Versión: $version_elegida - Puerto: $puerto</h1>" > /usr/share/nginx/html/index.html
    
    echo "[*] Configurando Firewall (firewalld)..."
    firewall-cmd --add-port="$puerto/tcp" --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    
    echo "[*] Reiniciando servicio para aplicar cambios..."
    # OJO: Si Apache está corriendo en el 80, Nginx DEBE ir en otro puerto o fallará al arrancar
    systemctl enable nginx > /dev/null 2>&1
    systemctl restart nginx
    
    echo -e "\n[OK] Nginx desplegado y asegurado con éxito en el puerto $puerto."
}

instalar_tomcat() {
    local puerto=$1
    echo -e "\n--- Iniciando aprovisionamiento de Tomcat ---"
    
    local version_elegida
    version_elegida=$(seleccionar_version "tomcat")
    if [ -z "$version_elegida" ]; then return 1; fi
    
    echo "[*] Instalando silenciosamente Tomcat y dependencias Java (Versión: $version_elegida)..."
    # Instalamos tomcat y su panel de administración web
    dnf install -yq "tomcat-$version_elegida" tomcat-webapps tomcat-admin-webapps
    
    echo "[*] Configurando puerto $puerto en server.xml..."
    # Tomcat por defecto usa el 8080. Usamos sed para buscar esa línea exacta en el XML y cambiarla
    sed -i "s/port=\"8080\"/port=\"$puerto\"/g" /etc/tomcat/server.xml
    
    echo "[*] Aplicando Hardening (Seguridad) exigido por la rúbrica..."
    # 1. Ocultar la versión exacta de Tomcat y Java en las respuestas de error
    sed -i 's/<Host name="localhost"  appBase="webapps"/<Host name="localhost"  appBase="webapps">\n        <Valve className="org.apache.catalina.valves.ErrorReportValve" showReport="false" showServerInfo="false" \/>/g' /etc/tomcat/server.xml
    
    # 2. Alterar la cabecera "Server" para que no diga "Apache-Coyote/1.1"
    sed -i "s/protocol=\"HTTP\/1.1\"/protocol=\"HTTP\/1.1\" server=\"AppServer Secreto\"/g" /etc/tomcat/server.xml
    
    echo "[*] Configurando Firewall (firewalld)..."
    firewall-cmd --add-port="$puerto/tcp" --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    
    echo "[*] Reiniciando servicio para aplicar cambios..."
    systemctl enable tomcat > /dev/null 2>&1
    systemctl restart tomcat
    
    echo -e "\n[OK] Tomcat desplegado y asegurado con éxito en el puerto $puerto."
}

# ==========================================
# MENÚ HTTP
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
        echo "  0) Regresar al Menú Principal"
        echo "========================================================="
        read -p "Ingrese una opción: " opcion

        if [[ "$opcion" == "0" ]]; then break; fi
        if [[ ! "$opcion" =~ ^[1-3]$ ]]; then
            echo "[!] Error: Opción no válida."
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

        echo ""
        read -p "Presione Enter para continuar..."
    done
}