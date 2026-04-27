#!/bin/bash
# ============================================================
# Archivo: practica10.sh
# Practica 10 - Contenedores Docker en AlmaLinux 9
# Servicios: Nginx, PostgreSQL, FTP
# ============================================================

set -e

# ==========================================
# CONFIGURACION GLOBAL
# ==========================================
RED_DOCKER="infra_red"
SUBRED="172.20.0.0/16"
GATEWAY="172.20.0.1"
IP_NGINX="172.20.0.10"
IP_POSTGRES="172.20.0.20"
IP_FTP="172.20.0.30"
VOL_DB="db_data"
VOL_WEB="web_content"
DIR_BASE="/opt/practica10"
DIR_NGINX="$DIR_BASE/nginx"
DIR_FTP="$DIR_BASE/ftp"
DIR_BACKUP="$DIR_BASE/backups"
POSTGRES_DB="reprobados_db"
POSTGRES_USER="admindb"
POSTGRES_PASS="DbPass2026!"
FTP_USER="ftpuser"
FTP_PASS="FtpPass2026!"
LOG_FILE="$DIR_BASE/practica10.log"

# Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1" | tee -a "$LOG_FILE"; }
ok()  { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}[!]${NC} $1" | tee -a "$LOG_FILE"; }

pause_menu() { read -p "Presiona Enter para continuar..."; }

# ==========================================
# MODULO 1: INSTALAR DOCKER
# ==========================================
instalar_docker() {
    clear
    echo "========================================="
    echo " 1. INSTALAR DOCKER EN ALMALINUX 9"
    echo "========================================="

    if command -v docker &>/dev/null; then
        ok "Docker ya esta instalado: $(docker --version)"
        pause_menu; return
    fi

    log "Actualizando repositorios..."
    dnf update -yq

    log "Instalando dependencias..."
    dnf install -yq yum-utils device-mapper-persistent-data lvm2

    log "Agregando repositorio oficial de Docker..."
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    log "Instalando Docker CE..."
    dnf install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log "Iniciando y habilitando Docker..."
    systemctl enable --now docker

    log "Agregando usuario actual al grupo docker..."
    usermod -aG docker root 2>/dev/null || true

    ok "Docker instalado: $(docker --version)"
    ok "Docker Compose: $(docker compose version)"
    pause_menu
}

# ==========================================
# MODULO 2: CREAR ESTRUCTURA DE DIRECTORIOS
# ==========================================
crear_estructura() {
    clear
    echo "========================================="
    echo " 2. CREAR ESTRUCTURA DE DIRECTORIOS"
    echo "========================================="

    log "Creando directorios base..."
    mkdir -p "$DIR_NGINX/html/css"
    mkdir -p "$DIR_NGINX/html/img"
    mkdir -p "$DIR_FTP/data"
    mkdir -p "$DIR_BACKUP"

    # Pagina web personalizada con CSS e imagen placeholder
    log "Creando pagina web personalizada..."
    cat > "$DIR_NGINX/html/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Practica 10 - Contenedores</title>
    <link rel="stylesheet" href="/css/estilo.css">
</head>
<body>
    <header>
        <img src="/img/logo.png" alt="Logo" onerror="this.style.display='none'">
        <h1>Infraestructura con Contenedores Docker</h1>
        <p>Practica 10 - Administracion de Sistemas</p>
    </header>
    <main>
        <div class="card">
            <h2>Servicios Activos</h2>
            <ul>
                <li>Nginx (Servidor Web) - Alpine Linux</li>
                <li>PostgreSQL (Base de Datos)</li>
                <li>vsftpd (Servidor FTP)</li>
            </ul>
        </div>
        <div class="card">
            <h2>Red Docker</h2>
            <p>Red: infra_red (172.20.0.0/16)</p>
            <p>Nginx: 172.20.0.10</p>
            <p>PostgreSQL: 172.20.0.20</p>
            <p>FTP: 172.20.0.30</p>
        </div>
    </main>
    <footer>
        <p>Maria Leticia Munoz Carlon | reprobados.com</p>
    </footer>
</body>
</html>
HTML

    cat > "$DIR_NGINX/html/css/estilo.css" << 'CSS'
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: Arial, sans-serif; background: #f0f4f8; color: #333; }
header { background: #1a3a5c; color: white; padding: 2rem; text-align: center; }
header img { height: 60px; margin-bottom: 1rem; }
header h1 { font-size: 2rem; margin-bottom: 0.5rem; }
header p { opacity: 0.8; }
main { max-width: 900px; margin: 2rem auto; padding: 0 1rem; display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; }
.card { background: white; border-radius: 8px; padding: 1.5rem; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
.card h2 { color: #1a3a5c; margin-bottom: 1rem; border-bottom: 2px solid #e0e8f0; padding-bottom: 0.5rem; }
.card ul { list-style: none; }
.card ul li { padding: 0.4rem 0; border-bottom: 1px solid #f0f0f0; }
.card ul li::before { content: "✓ "; color: #27ae60; }
.card p { margin: 0.3rem 0; font-family: monospace; }
footer { text-align: center; padding: 1rem; background: #1a3a5c; color: white; margin-top: 2rem; }
CSS

    # Crear imagen placeholder SVG como logo
    cat > "$DIR_NGINX/html/img/logo.png" << 'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="60" height="60" viewBox="0 0 60 60">
  <circle cx="30" cy="30" r="28" fill="#2980b9"/>
  <text x="30" y="38" font-size="28" text-anchor="middle" fill="white" font-family="Arial">D</text>
</svg>
SVG

    ok "Estructura de directorios creada en $DIR_BASE"
    pause_menu
}

# ==========================================
# MODULO 3: CREAR DOCKERFILES
# ==========================================
crear_dockerfiles() {
    clear
    echo "========================================="
    echo " 3. CREAR DOCKERFILES PERSONALIZADOS"
    echo "========================================="

    # Dockerfile para Nginx (Alpine - imagen ligera)
    log "Creando Dockerfile para Nginx..."
    cat > "$DIR_NGINX/Dockerfile" << 'DOCKERFILE'
# Imagen base ligera Alpine Linux
FROM nginx:alpine

# Metadatos
LABEL maintainer="Maria Leticia Munoz Carlon"
LABEL descripcion="Servidor Nginx personalizado - Practica 10"
LABEL version="1.0"

# Eliminar firma del servidor (Server Tokens)
RUN sed -i 's/^#server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf || \
    echo "server_tokens off;" >> /etc/nginx/conf.d/default.conf

# Crear usuario no administrativo para ejecutar Nginx
RUN addgroup -S webgroup && adduser -S webuser -G webgroup

# Copiar configuracion personalizada
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copiar contenido web
COPY html/ /usr/share/nginx/html/

# Permisos correctos
RUN chown -R webuser:webgroup /usr/share/nginx/html && \
    chown -R webuser:webgroup /var/cache/nginx && \
    chown -R webuser:webgroup /var/log/nginx && \
    touch /var/run/nginx.pid && \
    chown webuser:webgroup /var/run/nginx.pid

# Ejecutar como usuario no administrativo
USER webuser

# Exponer puerto
EXPOSE 80

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
DOCKERFILE

    # Configuracion Nginx personalizada
    cat > "$DIR_NGINX/nginx.conf" << 'NGINXCONF'
server {
    listen 80;
    server_name _;

    # Eliminar firma del servidor
    server_tokens off;

    # Cabeceras de seguridad
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    # Logs
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
}
NGINXCONF

    ok "Dockerfile Nginx creado."

    # Dockerfile para FTP (basado en Alpine)
    log "Creando Dockerfile para FTP..."
    mkdir -p "$DIR_FTP"
    cat > "$DIR_FTP/Dockerfile" << 'FTPDOCKERFILE'
FROM alpine:3.19

LABEL maintainer="Maria Leticia Munoz Carlon"
LABEL descripcion="Servidor FTP vsftpd personalizado - Practica 10"

# Instalar vsftpd
RUN apk add --no-cache vsftpd

# Crear usuario FTP
RUN adduser -D -s /sbin/nologin ftpuser && \
    echo "ftpuser:FtpPass2026!" | chpasswd

# Crear directorio FTP
RUN mkdir -p /ftp/data && \
    chown ftpuser:ftpuser /ftp/data && \
    chmod 755 /ftp/data

# Configuracion vsftpd
COPY vsftpd.conf /etc/vsftpd/vsftpd.conf

EXPOSE 21 21100-21110

CMD ["/usr/sbin/vsftpd", "/etc/vsftpd/vsftpd.conf"]
FTPDOCKERFILE

    # Configuracion vsftpd
    cat > "$DIR_FTP/vsftpd.conf" << 'VSFTPD'
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
local_root=/ftp/data
pasv_enable=YES
pasv_min_port=21100
pasv_max_port=21110
pasv_address=172.20.0.30
userlist_enable=NO
VSFTPD

    ok "Dockerfile FTP creado."
    pause_menu
}

# ==========================================
# MODULO 4: CONSTRUIR IMAGENES
# ==========================================
construir_imagenes() {
    clear
    echo "========================================="
    echo " 4. CONSTRUIR IMAGENES DOCKER"
    echo "========================================="

    log "Construyendo imagen Nginx personalizada..."
    docker build -t nginx-practica10:1.0 "$DIR_NGINX/"
    ok "Imagen nginx-practica10:1.0 construida."

    log "Construyendo imagen FTP personalizada..."
    docker build -t ftp-practica10:1.0 "$DIR_FTP/"
    ok "Imagen ftp-practica10:1.0 construida."

    log "Descargando imagen PostgreSQL..."
    docker pull postgres:15-alpine
    ok "Imagen postgres:15-alpine descargada."

    log "Imagenes disponibles:"
    docker images | grep -E "nginx-practica10|ftp-practica10|postgres"
    pause_menu
}

# ==========================================
# MODULO 5: CREAR RED Y VOLUMENES
# ==========================================
crear_red_volumenes() {
    clear
    echo "========================================="
    echo " 5. CREAR RED Y VOLUMENES DOCKER"
    echo "========================================="

    # Crear red personalizada
    if docker network ls | grep -q "$RED_DOCKER"; then
        log "Red $RED_DOCKER ya existe."
    else
        log "Creando red personalizada $RED_DOCKER ($SUBRED)..."
        docker network create \
            --driver bridge \
            --subnet "$SUBRED" \
            --gateway "$GATEWAY" \
            --opt "com.docker.network.bridge.name"="br_infra" \
            "$RED_DOCKER"
        ok "Red $RED_DOCKER creada."
    fi

    # Crear volumenes
    for vol in "$VOL_DB" "$VOL_WEB"; do
        if docker volume ls | grep -q "$vol"; then
            log "Volumen $vol ya existe."
        else
            docker volume create "$vol"
            ok "Volumen $vol creado."
        fi
    done

    log "Red creada:"
    docker network inspect "$RED_DOCKER" | grep -E "Subnet|Gateway|Name"

    log "Volumenes creados:"
    docker volume ls | grep -E "$VOL_DB|$VOL_WEB"
    pause_menu
}

# ==========================================
# MODULO 6: INICIAR CONTENEDORES
# ==========================================
iniciar_contenedores() {
    clear
    echo "========================================="
    echo " 6. INICIAR CONTENEDORES"
    echo "========================================="

    # Detener contenedores previos si existen
    for c in nginx-web postgres-db ftp-server; do
        if docker ps -a | grep -q "$c"; then
            log "Deteniendo contenedor previo: $c..."
            docker rm -f "$c" 2>/dev/null || true
        fi
    done

    # Iniciar PostgreSQL
    log "Iniciando contenedor PostgreSQL..."
    docker run -d \
        --name postgres-db \
        --network "$RED_DOCKER" \
        --ip "$IP_POSTGRES" \
        --restart unless-stopped \
        -e POSTGRES_DB="$POSTGRES_DB" \
        -e POSTGRES_USER="$POSTGRES_USER" \
        -e POSTGRES_PASSWORD="$POSTGRES_PASS" \
        -v "$VOL_DB:/var/lib/postgresql/data" \
        -v "$DIR_BACKUP:/backups" \
        --memory="512m" \
        --cpus="0.5" \
        postgres:15-alpine
    ok "PostgreSQL iniciado en $IP_POSTGRES"

    # Esperar a que PostgreSQL este listo
    log "Esperando a que PostgreSQL este listo..."
    sleep 5

    # Iniciar Nginx
    log "Iniciando contenedor Nginx..."
    docker run -d \
        --name nginx-web \
        --network "$RED_DOCKER" \
        --ip "$IP_NGINX" \
        --restart unless-stopped \
        -p 8080:80 \
        -v "$VOL_WEB:/usr/share/nginx/html" \
        --memory="256m" \
        --cpus="0.5" \
        nginx-practica10:1.0
    ok "Nginx iniciado en $IP_NGINX (puerto host: 8080)"

    # Iniciar FTP
    log "Iniciando contenedor FTP..."
    docker run -d \
        --name ftp-server \
        --network "$RED_DOCKER" \
        --ip "$IP_FTP" \
        --restart unless-stopped \
        -p 21:21 \
        -p 21100-21110:21100-21110 \
        -v "$DIR_FTP/data:/ftp/data" \
        -v "$VOL_WEB:/ftp/data/web" \
        --memory="128m" \
        --cpus="0.25" \
        ftp-practica10:1.0
    ok "FTP iniciado en $IP_FTP"

    sleep 3
    log "Estado de contenedores:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Networks}}"
    pause_menu
}

# ==========================================
# MODULO 7: CONFIGURAR BACKUP AUTOMATICO
# ==========================================
configurar_backup() {
    clear
    echo "========================================="
    echo " 7. CONFIGURAR BACKUP AUTOMATICO DE BD"
    echo "========================================="

    # Script de backup
    cat > "$DIR_BASE/backup_postgres.sh" << BACKUP
#!/bin/bash
# Backup automatico de PostgreSQL
FECHA=\$(date +%Y%m%d_%H%M%S)
docker exec postgres-db pg_dump -U $POSTGRES_USER $POSTGRES_DB > $DIR_BACKUP/backup_\$FECHA.sql
echo "[\$(date)] Backup generado: backup_\$FECHA.sql" >> $DIR_BASE/practica10.log
# Mantener solo los ultimos 7 backups
ls -t $DIR_BACKUP/backup_*.sql | tail -n +8 | xargs rm -f 2>/dev/null || true
BACKUP
    chmod +x "$DIR_BASE/backup_postgres.sh"

    # Agregar cron job cada hora
    (crontab -l 2>/dev/null | grep -v backup_postgres; echo "0 * * * * $DIR_BASE/backup_postgres.sh") | crontab -

    # Ejecutar backup inicial
    log "Ejecutando backup inicial..."
    bash "$DIR_BASE/backup_postgres.sh"

    ok "Backup automatico configurado (cada hora en $DIR_BACKUP/)"
    log "Backups disponibles:"
    ls -lh "$DIR_BACKUP/" 2>/dev/null || echo "Sin backups aun"
    pause_menu
}

# ==========================================
# MODULO 8: PRUEBAS DE VALIDACION
# ==========================================
ejecutar_pruebas() {
    clear
    echo "========================================="
    echo " 8. PRUEBAS DE VALIDACION"
    echo "========================================="

    # Prueba 10.1 - Persistencia de BD
    echo ""
    echo "--- Prueba 10.1: Persistencia de Base de Datos ---"
    log "Creando tabla de prueba en PostgreSQL..."
    docker exec postgres-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "CREATE TABLE IF NOT EXISTS usuarios_prueba (id SERIAL PRIMARY KEY, nombre VARCHAR(50), fecha TIMESTAMP DEFAULT NOW());"
    docker exec postgres-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "INSERT INTO usuarios_prueba (nombre) VALUES ('jgarcia'), ('sperez'), ('mlopez');"
    docker exec postgres-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "SELECT * FROM usuarios_prueba;"
    ok "Datos insertados. Ahora elimina el contenedor con: docker rm -f postgres-db"
    ok "Luego reinicia con la opcion 6 y verifica que los datos persisten."
    echo ""

    # Prueba 10.2 - Aislamiento de Red
    echo "--- Prueba 10.2: Aislamiento de Red ---"
    log "Ping desde nginx-web hacia postgres-db por nombre..."
    docker exec nginx-web ping -c 3 postgres-db 2>/dev/null && \
        ok "Ping exitoso: nginx-web puede ver postgres-db por nombre" || \
        err "Ping fallido - instalar ping en nginx: docker exec nginx-web apk add iputils"

    log "Inspeccion de red $RED_DOCKER:"
    docker network inspect "$RED_DOCKER" | grep -A5 "Containers"
    echo ""

    # Prueba 10.3 - Permisos FTP
    echo "--- Prueba 10.3: Permisos FTP ---"
    log "Verificando que el volumen web es accesible desde FTP..."
    docker exec ftp-server ls -la /ftp/data/ 2>/dev/null && \
        ok "Directorio FTP accesible" || \
        err "Error al acceder al directorio FTP"
    echo ""

    # Prueba 10.4 - Limites de Recursos
    echo "--- Prueba 10.4: Limites de Recursos ---"
    log "Estadisticas de contenedores (limites de memoria y CPU):"
    docker stats --no-stream --format \
        "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
    echo ""
    ok "Todas las pruebas ejecutadas."
    pause_menu
}

# ==========================================
# MODULO 9: RESUMEN
# ==========================================
mostrar_resumen() {
    clear
    echo "========================================="
    echo " RESUMEN DE INFRAESTRUCTURA"
    echo "========================================="

    echo ""
    echo "Contenedores:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

    echo ""
    echo "Volumenes:"
    docker volume ls | grep -E "$VOL_DB|$VOL_WEB"

    echo ""
    echo "Red $RED_DOCKER:"
    docker network inspect "$RED_DOCKER" --format \
        "Subnet: {{range .IPAM.Config}}{{.Subnet}}{{end}}" 2>/dev/null

    echo ""
    echo "Imagenes personalizadas:"
    docker images | grep -E "nginx-practica10|ftp-practica10"

    echo ""
    echo "Acceso a servicios:"
    echo "  Web  : http://$(hostname -I | awk '{print $1}'):8080"
    echo "  BD   : postgres://$(hostname -I | awk '{print $1}'):5432/$POSTGRES_DB"
    echo "  FTP  : ftp://$(hostname -I | awk '{print $1}'):21 (user: $FTP_USER)"
    echo ""
    pause_menu
}

# ==========================================
# MENU PRINCIPAL
# ==========================================
menu_dockers() {
    while true; do
        clear
        echo "========================================================="
        echo "   PRACTICA 10 - CONTENEDORES DOCKER - ALMALINUX 9"
        echo "========================================================="
        echo "  1) Instalar Docker"
        echo "  2) Crear estructura de directorios y pagina web"
        echo "  3) Crear Dockerfiles personalizados"
        echo "  4) Construir imagenes Docker"
        echo "  5) Crear red y volumenes"
        echo "  6) Iniciar contenedores"
        echo "  7) Configurar backup automatico de BD"
        echo "  8) Ejecutar pruebas de validacion"
        echo "  9) Ver resumen de infraestructura"
        echo "  0) Salir"
        echo "========================================================="
        read -p "Seleccione una opcion: " op

        case $op in
            1) instalar_docker ;;
            2) crear_estructura ;;
            3) crear_dockerfiles ;;
            4) construir_imagenes ;;
            5) crear_red_volumenes ;;
            6) iniciar_contenedores ;;
            7) configurar_backup ;;
            8) ejecutar_pruebas ;;
            9) mostrar_resumen ;;
            0) echo "Saliendo..."; exit 0 ;;
            *) echo "Opcion no valida."; sleep 1 ;;
        esac
    done
}

# Crear directorio de logs
mkdir -p "$DIR_BASE"
touch "$LOG_FILE"

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo "[!] Ejecuta como root: sudo bash practica10.sh"
    exit 1
fi