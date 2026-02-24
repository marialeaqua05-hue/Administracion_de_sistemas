#!/bin/bash

# ==============================================================================
# LIBRERÍA DE FUNCIONES DNS (BIND9) - V3.0
# Características: Aislamiento de Router + Soporte Automático PTR (Zona Inversa)
# ==============================================================================

# --- VARIABLES GLOBALES ---
# Detectamos la interfaz activa automáticamente (excluyendo loopback)
INTERFACE=$(nmcli -t -f DEVICE,TYPE device | grep ":ethernet" | head -n1 | cut -d: -f1)
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

function pause(){ echo ""; read -p "Presiona Enter para continuar..."; }
function log_msg() { echo -e "${GREEN}[OK]${NC} $1"; }
function log_err() { echo -e "${RED}[ERROR]${NC} $1"; }
function log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
function limpiar_str() { echo "$1" | tr -d '\r'; }

function detectar_ip() {
    # Busca la IP configurada manualmente en la interfaz detectada
    if [ -z "$INTERFACE" ]; then
        log_err "No se detectó interfaz de red."
        return 1
    fi
    
    SERVER_IP=$(nmcli -g IP4.ADDRESS device show $INTERFACE | head -n1 | cut -d/ -f1)
    
    if [ -z "$SERVER_IP" ]; then
        return 1
    fi
    return 0
}

# ==============================================================================
# 2. INSTALACIÓN Y CONFIGURACIÓN DEL SERVICIO
# ==============================================================================

function instalar_bind() {
    clear
    echo -e "${YELLOW}=== GESTOR DE INSTALACIÓN DNS (LINUX) ===${NC}"

    # 1. Instalar Paquetes
    if rpm -q bind &> /dev/null; then
        log_warn "BIND ya está instalado."
    else
        echo "Instalando bind y bind-utils..."
        dnf install bind bind-utils -y > /dev/null 2>&1
        if [ $? -eq 0 ]; then log_msg "Instalado correctamente."; else log_err "Error al instalar."; pause; return; fi
    fi

    # 2. Configurar named.conf (Abrir puerto 53)
    if [ ! -f "${NAMED_CONF}.bak" ]; then cp $NAMED_CONF "${NAMED_CONF}.bak"; fi
    sed -i 's/listen-on port 53 { 127.0.0.1; };/listen-on port 53 { any; };/' $NAMED_CONF
    sed -i 's/allow-query     { localhost; };/allow-query     { any; };/' $NAMED_CONF

    # 3. Vincular archivo de zonas de usuario
    if [ ! -f "$USER_ZONES_CONF" ]; then
        touch $USER_ZONES_CONF
        chown root:named $USER_ZONES_CONF
        chmod 640 $USER_ZONES_CONF
        if ! grep -q "$USER_ZONES_CONF" $NAMED_CONF; then echo "include \"$USER_ZONES_CONF\";" >> $NAMED_CONF; fi
    fi

    # 4. Iniciar Servicio y Firewall
    systemctl enable named --now > /dev/null 2>&1
    firewall-cmd --add-service=dns --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1

    # ============================================================
    # PASO CRÍTICO: AISLAMIENTO TOTAL (Borrar DNS del Router)
    # ============================================================
    detectar_ip
    if [ -z "$SERVER_IP" ]; then log_err "No se detectó IP estática."; pause; return; fi

    echo ""
    echo -e "${YELLOW}[CONFIG] Configurando Resolución Local...${NC}"
    echo "   IP del Servidor: $SERVER_IP"
    echo "   Aplicando esta IP como ÚNICO DNS en $INTERFACE..."

    # Ignorar DNS automáticos (del router/DHCP externo)
    nmcli con mod "System $INTERFACE" ipv4.ignore-auto-dns yes 2>/dev/null || nmcli con mod "$INTERFACE" ipv4.ignore-auto-dns yes
    
    # Establecer NUESTRA IP como único DNS
    nmcli con mod "System $INTERFACE" ipv4.dns "$SERVER_IP" 2>/dev/null || nmcli con mod "$INTERFACE" ipv4.dns "$SERVER_IP"
    
    # Reiniciar interfaz para aplicar cambios
    nmcli con down "System $INTERFACE" >/dev/null 2>&1 || nmcli con down "$INTERFACE" >/dev/null 2>&1
    nmcli con up "System $INTERFACE" >/dev/null 2>&1 || nmcli con up "$INTERFACE" >/dev/null 2>&1
    
    sleep 2
    log_msg "El servidor ahora se consulta SOLO a sí mismo."
    echo "Verificación (/etc/resolv.conf):"
    cat /etc/resolv.conf | grep nameserver
    pause
}

# ==============================================================================
# 3. GESTIÓN DE DOMINIOS (ZONA DIRECTA + INVERSA/PTR)
# ==============================================================================

function agregar_dominio() {
    clear
    echo -e "${YELLOW}=== AGREGAR NUEVO DOMINIO ===${NC}"
    detectar_ip
    
    if [ -z "$SERVER_IP" ]; then log_err "Sin IP detectada."; pause; return; fi

    read -p "Nombre del Dominio (ej. reprobados.com): " DOMINIO
    DOMINIO=$(limpiar_str "$DOMINIO")

    if grep -q "zone \"$DOMINIO\"" $USER_ZONES_CONF; then
        log_warn "El dominio '$DOMINIO' ya existe."
        pause; return
    fi

    # --- PARTE A: ZONA DIRECTA (Nombre -> IP) ---
    echo "[...] Configurando Zona Directa..."
    ZONE_FILE="$ZONE_DIR/db.$DOMINIO"
    
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
    chown root:named $ZONE_FILE

    # Registrar Zona Directa
cat <<EOF >> $USER_ZONES_CONF
zone "$DOMINIO" IN {
    type master;
    file "$ZONE_FILE";
    allow-update { none; };
};
EOF
    log_msg "Zona Directa creada."

    # --- PARTE B: ZONA INVERSA (PTR) AUTOMÁTICA ---
    echo "[...] Configurando Zona Inversa (PTR)..."
    
    # Calcular octetos: IP=192.168.100.10 -> REV_ZONE=100.168.192.in-addr.arpa
    IFS='.' read -r i1 i2 i3 i4 <<< "$SERVER_IP"
    REV_ZONE_NAME="$i3.$i2.$i1.in-addr.arpa"
    REV_ZONE_FILE="$ZONE_DIR/db.$i3.$i2.$i1"
    HOST_ID="$i4"

    # Verificar si la zona inversa ya está registrada, si no, crearla
    if ! grep -q "zone \"$REV_ZONE_NAME\"" $USER_ZONES_CONF; then
        echo "   -> Creando archivo de Zona Inversa nueva..."
        
cat <<EOF > $REV_ZONE_FILE
\$TTL 1D
@       IN SOA  ns1.$DOMINIO. root.$DOMINIO. (
                                        0       ; serial
                                        1D      ; refresh
                                        1H      ; retry
                                        1W      ; expire
                                        3H )    ; minimum
@       IN      NS      ns1.$DOMINIO.
EOF
        chown root:named $REV_ZONE_FILE
        
        # Registrar Zona Inversa en config
cat <<EOF >> $USER_ZONES_CONF
zone "$REV_ZONE_NAME" IN {
    type master;
    file "$REV_ZONE_FILE";
    allow-update { none; };
};
EOF
    fi

    # Agregar el registro PTR al archivo existente
    # Formato: 10    IN    PTR    reprobados.com.
    if ! grep -q "$HOST_ID.*PTR.*$DOMINIO" $REV_ZONE_FILE; then
        echo "$HOST_ID    IN    PTR    $DOMINIO." >> $REV_ZONE_FILE
        log_msg "Registro PTR agregado."
    else
        log_warn "El PTR ya existía."
    fi

    # Recargar o Iniciar BIND
    if named-checkconf; then
        if systemctl is-active --quiet named; then
            systemctl reload named
        else
            systemctl start named
            systemctl enable named
        fi
        log_msg "Configuración aplicada exitosamente."
    else
        log_err "Error de sintaxis BIND."
    fi
    pause
}

function eliminar_dominio() {
    clear
    echo -e "${YELLOW}=== ELIMINAR DOMINIO ===${NC}"
    read -p "Dominio a eliminar: " DOMINIO
    DOMINIO=$(limpiar_str "$DOMINIO")

    if ! grep -q "zone \"$DOMINIO\"" $USER_ZONES_CONF; then
        log_err "No existe la configuración para $DOMINIO"
        pause; return
    fi

    # Respaldo
    cp $USER_ZONES_CONF "${USER_ZONES_CONF}.bak"

    # Borrar bloque de configuración (Usando la lógica robusta de V3.0)
    sed -i "/zone \"$DOMINIO\"/,/^};/d" $USER_ZONES_CONF
    
    # Borrar archivo físico
    if [ -f "$ZONE_DIR/db.$DOMINIO" ]; then
        rm -f "$ZONE_DIR/db.$DOMINIO"
    fi

    # Nota: No borramos la zona inversa completa porque podría tener otros dominios,
    # pero para esta práctica es suficiente con quitar la directa.
    
    if named-checkconf; then
        systemctl reload named
        log_msg "Dominio $DOMINIO eliminado."
    else
        log_err "Error al recargar. Restaurando respaldo..."
        cp "${USER_ZONES_CONF}.bak" $USER_ZONES_CONF
        systemctl reload named
    fi
    pause
}

function listar_dominios() {
    clear
    echo -e "${YELLOW}=== ZONAS REGISTRADAS ===${NC}"
    if [ -f "$USER_ZONES_CONF" ]; then
        grep "zone \"" $USER_ZONES_CONF | cut -d\" -f2
    else
        echo "Sin zonas configuradas."
    fi
    pause
}

function probar_dns() {
    clear
    echo -e "${YELLOW}=== PRUEBA DE RESOLUCIÓN ===${NC}"
    detectar_ip
    
    # Auto-Corrección antes de probar
    if [ ! -z "$SERVER_IP" ]; then
        nmcli con mod "System $INTERFACE" ipv4.dns "$SERVER_IP" 2>/dev/null || nmcli con mod "$INTERFACE" ipv4.dns "$SERVER_IP"
    fi

    read -p "Dominio a probar: " DOMINIO
    DOMINIO=$(limpiar_str "$DOMINIO")
    
    echo ""
    echo -e "${YELLOW}[TEST 1] Búsqueda Directa forzada al DNS local (nslookup $DOMINIO $SERVER_IP)${NC}"
    nslookup $DOMINIO $SERVER_IP
    
    echo ""
    echo -e "${YELLOW}[TEST 2] Búsqueda Inversa forzada al DNS local (nslookup $SERVER_IP $SERVER_IP)${NC}"
    nslookup $SERVER_IP $SERVER_IP
    
    echo ""
    echo -e "${YELLOW}[TEST 3] Ping...${NC}"
    ping -c 2 $DOMINIO
    pause
}

# Validar Root
if [ "$EUID" -ne 0 ]; then
    echo "Ejecutar con sudo."
    exit 1
fi

# Menú
function menu_dns() {
    while true; do
        clear
        echo -e "${YELLOW}=== SERVIDOR DNS AUTOMATIZADO ===${NC}"
        # La IP ya viene configurada del menú DHCP, así que vamos directo al grano:
        echo "1. Instalar BIND9 y Preparar DNS Local"
        echo "2. Agregar Dominio (ABC)"
        echo "3. Eliminar Dominio (ABC)"
        echo "4. Listar Dominios (ABC)"
        echo "5. Probar Resolución (Ping/Nslookup)"
        echo "6. Regresar al Menú DHCP"
    
        read -p "Opción: " op
        case $op in
            1) instalar_bind ;;     # Detecta la IP sola y configura Bind
            2) agregar_dominio ;;   # Usa la IP detectada para crear la zona
            3) eliminar_dominio ;;
            4) listar_dominios ;;
            5) probar_dns ;;
            6) return 0 ;;            # Regresa al menú DHCP
            *) echo "Opción inválida"; sleep 1 ;;
        esac
    done
}