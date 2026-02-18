#!/bin/bash

# ==============================================================================
# LIBRERÍA DE FUNCIONES DNS (BIND9)
# Archivo: dns_lib.sh
# Versión: 2.0 (Lógica Ajustada: DNS Local = IP Servidor)
# ==============================================================================

# --- VARIABLES GLOBALES ---
INTERFACE="enp0s8" # ¡Ajusta esto si tu interfaz es diferente!
NAMED_CONF="/etc/named.conf"
USER_ZONES_CONF="/etc/named.user-zones.conf"
ZONE_DIR="/var/named"
SERVER_IP=""

# --- COLORES ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==============================================================================
# 1. FUNCIONES AUXILIARES
# ==============================================================================

function pause(){
    echo ""
    read -p "Presiona Enter para continuar..."
}

function log_msg() { echo -e "${GREEN}[OK]${NC} $1"; }
function log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

function limpiar_str() { echo "$1" | tr -d '\r'; }

function validar_ip() {
    local ip=$(limpiar_str "$1")
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then return 1; fi
    if [[ "$ip" == "0.0.0.0" || "$ip" == "127.0.0.1" || "$ip" == "255.255.255.255" ]]; then return 1; fi
    return 0
}

function calcular_mascara() {
    local oct=$(echo $1 | cut -d. -f1)
    if [ "$oct" -lt 128 ]; then echo "8"; 
    elif [ "$oct" -lt 192 ]; then echo "16"; 
    else echo "24"; fi
}

function detectar_ip() {
    # Intenta obtener la IP configurada actualmente
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(nmcli -g IP4.ADDRESS device show $INTERFACE | head -n1 | cut -d/ -f1)
    fi
}

# ==============================================================================
# 2. CONFIGURACIÓN DE RED (ESTILO DHCP)
# ==============================================================================

function configurar_ip() {
    clear
    echo "=== 1. CONFIGURACIÓN DE RED (IP SERVIDOR) ==="
    
    detectar_ip
    echo "IP Actual: ${SERVER_IP:-No detectada}"
    echo "¿Desea configurar una nueva IP Estática? (s/n)"
    read -r resp

    if [[ "$resp" == "s" || "$resp" == "S" ]]; then
        while true; do
            read -p "Ingrese IP del Servidor: " IP_INPUT
            IP_INPUT=$(limpiar_str "$IP_INPUT")
            if validar_ip $IP_INPUT; then SERVER_IP=$IP_INPUT; break; else log_err "IP inválida."; fi
        done

        CIDR=$(calcular_mascara $SERVER_IP)
        read -p "Ingrese Gateway (Enter para vacío): " GW
        GW=$(limpiar_str "$GW")

        log_msg "Aplicando configuración..."
        
        # COMANDO CORREGIDO: Agregamos ipv4.ignore-auto-dns yes
        nmcli con mod "System $INTERFACE" ipv4.addresses "$SERVER_IP/$CIDR" ipv4.gateway "$GW" ipv4.dns "8.8.8.8" ipv4.ignore-auto-dns yes ipv4.method manual 2>/dev/null || nmcli con mod "$INTERFACE" ipv4.addresses "$SERVER_IP/$CIDR" ipv4.gateway "$GW" ipv4.dns "8.8.8.8" ipv4.ignore-auto-dns yes ipv4.method manual
        
        nmcli con down "System $INTERFACE" 2>/dev/null || nmcli con down "$INTERFACE" >/dev/null 2>&1
        nmcli con up "System $INTERFACE" 2>/dev/null || nmcli con up "$INTERFACE" >/dev/null 2>&1
        sleep 3
        log_msg "Red configurada."
    else
        log_msg "Se mantiene la IP actual."
    fi
    pause
}

# ==============================================================================
# 3. INSTALACIÓN Y CAMBIO DE DNS A LOCAL
# ==============================================================================

function instalar_bind() {
    clear
    echo "=== 2. INSTALACIÓN DE BIND9 ==="

    # 1. Instalar (Idempotencia)
    if rpm -q bind &> /dev/null; then
        log_msg "BIND ya está instalado."
    else
        echo "Instalando paquetes..."
        dnf install bind bind-utils -y > /dev/null 2>&1
        if [ $? -eq 0 ]; then log_msg "Instalado correctamente."; else log_err "Error al instalar. Verifica internet."; pause; return; fi
    fi

    # 2. Configurar named.conf
    if [ ! -f "${NAMED_CONF}.bak" ]; then cp $NAMED_CONF "${NAMED_CONF}.bak"; fi
    sed -i 's/listen-on port 53 { 127.0.0.1; };/listen-on port 53 { any; };/' $NAMED_CONF
    sed -i 's/allow-query     { localhost; };/allow-query     { any; };/' $NAMED_CONF

    # 3. Configurar archivo de zonas de usuario
    if [ ! -f "$USER_ZONES_CONF" ]; then
        touch $USER_ZONES_CONF
        chown root:named $USER_ZONES_CONF
        chmod 640 $USER_ZONES_CONF
        if ! grep -q "$USER_ZONES_CONF" $NAMED_CONF; then echo "include \"$USER_ZONES_CONF\";" >> $NAMED_CONF; fi
    fi

    # 4. Iniciar Servicio
    systemctl enable named --now > /dev/null 2>&1
    firewall-cmd --add-service=dns --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1

    # ============================================================
    # PASO CLAVE MEJORADO: FORZAR DNS LOCAL Y PRIORIDAD
    # ============================================================
    detectar_ip
    echo ""
    echo "=== CONFIGURANDO DNS LOCAL ==="
    echo "Forzando a $SERVER_IP como DNS PRINCIPAL..."
    
    nmcli con mod "System $INTERFACE" ipv4.ignore-auto-dns yes 2>/dev/null || nmcli con mod "$INTERFACE" ipv4.ignore-auto-dns yes
    
    nmcli con mod "System $INTERFACE" ipv4.dns "$SERVER_IP" 2>/dev/null || nmcli con mod "$INTERFACE" ipv4.dns "$SERVER_IP"
    
    nmcli con mod "System $INTERFACE" ipv4.dns-priority -100 2>/dev/null || nmcli con mod "$INTERFACE" ipv4.dns-priority -100

    # 4. Reiniciar interfaz para aplicar
    echo "Aplicando cambios en la red..."
    nmcli con down "System $INTERFACE" 2>/dev/null || nmcli con down "$INTERFACE" >/dev/null 2>&1
    nmcli con up "System $INTERFACE" 2>/dev/null || nmcli con up "$INTERFACE" >/dev/null 2>&1
    
    log_msg "¡Listo! Ahora el servidor tiene prioridad absoluta."
    echo "Verificación (Tu IP debe salir PRIMERO):"
    cat /etc/resolv.conf
    pause
}

# ==============================================================================
# 4. GESTIÓN DE DOMINIOS (ABC) - APUNTANDO A LA IP DEL SERVIDOR
# ==============================================================================

function agregar_dominio() {
    clear
    echo "=== AGREGAR DOMINIO (ABC) ==="
    detectar_ip
    
    if [ -z "$SERVER_IP" ]; then log_err "No hay IP detectada."; pause; return; fi

    read -p "Nombre del Dominio (ej. reprobados.com): " DOMINIO
    DOMINIO=$(limpiar_str "$DOMINIO")

    if grep -q "zone \"$DOMINIO\"" $USER_ZONES_CONF; then
        log_err "El dominio ya existe."
        pause; return
    fi

    ZONE_FILE="$ZONE_DIR/db.$DOMINIO"
    echo "Creando zona para $DOMINIO apuntando a $SERVER_IP..."

    # CREACIÓN DEL ARCHIVO DE ZONA
    # Aquí es donde se cumple: "ping... me debe hacer ping a la ip de la maquina server"
cat <<EOF > $ZONE_FILE
\$TTL 1D
@       IN SOA  ns1.$DOMINIO. root.$DOMINIO. (
                                        0       ; serial
                                        1D      ; refresh
                                        1H      ; retry
                                        1W      ; expire
                                        3H )    ; minimum
@       IN      NS      ns1.$DOMINIO.
@       IN      A       $SERVER_IP
ns1     IN      A       $SERVER_IP
www     IN      A       $SERVER_IP
EOF
# Nota: Usé 'A' para www en lugar de CNAME para asegurar resolución directa a la IP, 
# aunque CNAME también funciona, A es un poco más robusto para este requisito.

    chown root:named $ZONE_FILE

    # Registrar en configuración
cat <<EOF >> $USER_ZONES_CONF
zone "$DOMINIO" IN {
    type master;
    file "$ZONE_FILE";
    allow-update { none; };
};
EOF

    if named-checkconf; then
        systemctl reload named
        log_msg "Dominio agregado exitosamente."
    else
        log_err "Error de sintaxis BIND."
    fi
    pause
}

function eliminar_dominio() {
    clear
    echo "=== ELIMINAR DOMINIO (ABC) ==="
    read -p "Dominio a eliminar: " DOMINIO
    DOMINIO=$(limpiar_str "$DOMINIO")

    # 1. Verificar si existe
    if ! grep -q "zone \"$DOMINIO\"" $USER_ZONES_CONF; then
        log_err "No existe la configuración para $DOMINIO"
        pause; return
    fi

    # 2. Respaldo de seguridad
    cp $USER_ZONES_CONF "${USER_ZONES_CONF}.bak"

    # 3. ELIMINACIÓN PRECISA (Aquí está el cambio clave)
    # El símbolo '^' significa "al principio de la línea".
    # Así evitamos borrar por error la línea de 'allow-update'.
    sed -i "/zone \"$DOMINIO\"/,/^};/d" $USER_ZONES_CONF
    
    # 4. Eliminar el archivo de zona físico
    if [ -f "$ZONE_DIR/db.$DOMINIO" ]; then
        rm -f "$ZONE_DIR/db.$DOMINIO"
        echo "Archivo de zona eliminado."
    fi

    # 5. Verificación y Recarga
    if named-checkconf; then
        systemctl reload named
        log_msg "Dominio $DOMINIO eliminado correctamente."
    else
        log_err "Error crítico al eliminar. Restaurando respaldo..."
        cp "${USER_ZONES_CONF}.bak" $USER_ZONES_CONF
        systemctl reload named
    fi
    
    pause
}

function listar_dominios() {
    clear
    echo "=== LISTA DE DOMINIOS (ABC) ==="
    if [ -f "$USER_ZONES_CONF" ]; then
        grep "zone \"" $USER_ZONES_CONF | cut -d\" -f2
    else
        echo "Sin dominios."
    fi
    pause
}

function probar_dns() {
    clear
    echo "=== VALIDACIÓN ==="
    read -p "Dominio a probar: " DOMINIO
    DOMINIO=$(limpiar_str "$DOMINIO")
    
    echo "--- nslookup $DOMINIO (Local) ---"
    nslookup $DOMINIO
    
    echo ""
    echo "--- Ping a $DOMINIO (Debe responder $SERVER_IP) ---"
    ping -c 2 $DOMINIO
    pause
}