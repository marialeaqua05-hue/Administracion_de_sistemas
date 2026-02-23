if [ -f "$SCRIPT_DIR/funciones_dns.sh" ]; then
	source "$SCRIPT_DIR/funciones_dns.sh"
fi

# --- UTILIDADES ---
function pause(){ read -p "Presiona Enter para continuar..."; }

function validar_ip() {
    local ip=$1
    # 1. Validar formato numérico (x.x.x.x)
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    
    # 2. Validar IPs prohibidas (Lista Negra)
    if [[ "$ip" == "0.0.0.0" || "$ip" == "127.0.0.1" || "$ip" == "255.255.255.255" ]]; then
        echo "Error: La IP $ip es reservada y no se puede usar."
        return 1
    fi
    
    # 3. Validar que los octetos sean <= 255
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    if [ "$i1" -gt 255 ] || [ "$i2" -gt 255 ] || [ "$i3" -gt 255 ] || [ "$i4" -gt 255 ]; then
        return 1
    fi

    return 0
}

function sumar_ip() {
    local ip=$1
    local base=$(echo $ip | cut -d. -f1-3)
    local last=$(echo $ip | cut -d. -f4)
    echo "$base.$((last + 1))"
}

function calcular_mascara() {
    local oct=$(echo $1 | cut -d. -f1)
    if [ "$oct" -lt 128 ]; then echo "255.0.0.0"; 
    elif [ "$oct" -lt 192 ]; then echo "255.255.0.0"; 
    else echo "255.255.255.0"; fi
}

# --- MÓDULOS ---
function menu_dns() {
    if [ -f "$LIB_FILE" ]; then
        bash "$LIB_FILE"
    else
        echo "Error: No encuentro el archivo $LIB_FILE"
        read -p "Enter..."
    fi
}

function instalar_dhcp() {
    clear
    echo "=== INSTALACION DHCP ==="
    dnf install dhcp-server -y > /dev/null 2>&1
    echo "Instalación completada (Silenciosa)."
    pause
}

function verificar_instalacion() {
    clear
    rpm -q dhcp-server
    pause
}

function configurar_dhcp() {
    clear
    echo "=== CONFIGURACION DHCP ==="
    
    # SELECCIÓN DE INTERFAZ MEJORADA
    echo "Interfaces detectadas:"
    nmcli device status | grep -v "lo" | awk '{print $1}'
    read -p "Escribe la interfaz a usar (Enter para $INTERFACE): " INT_USER
    if [ ! -z "$INT_USER" ]; then INTERFACE=$INT_USER; fi
    
    # DATOS
    read -p "Nombre Scope: " SCOPE_NAME
    while true; do
        read -p "IP Inicio (IP del Servidor): " IP_INPUT
        if validar_ip $IP_INPUT; then break; else echo "IP Inválida o Reservada."; fi
    done
    
    SERVER_IP=$IP_INPUT
    RANGE_START=$(sumar_ip $IP_INPUT)
    MASK=$(calcular_mascara $SERVER_IP)
    
    # LÓGICA CORREGIDA PARA SUBNET ID (Fix para error 'bad subnet')
    IFS='.' read -r i1 i2 i3 i4 <<< "$SERVER_IP"
    if [ "$MASK" == "255.0.0.0" ]; then
        SUBNET_ID="$i1.0.0.0"  # Clase A
        CIDR=8
    elif [ "$MASK" == "255.255.0.0" ]; then
        SUBNET_ID="$i1.$i2.0.0" # Clase B
        CIDR=16
    else
        SUBNET_ID="$i1.$i2.$i3.0" # Clase C
        CIDR=24
    fi

    echo "-> Configuración detectada:"
    echo "   IP Server: $SERVER_IP"
    echo "   Mascara:   $MASK (/$CIDR)"
    echo "   Subnet ID: $SUBNET_ID"
    
    while true; do 
        read -p "IP Final: " RANGE_END
        if validar_ip $RANGE_END; then break; else echo "IP Inválida."; fi
    done

    while true; do 
        read -p "Tiempo (seg): " LEASE
        if [[ "$LEASE" =~ ^[0-9]+$ ]]; then break; fi
    done
    
    while true; do
        read -p "Gateway (Enter vacio): " GW
        if [ -z "$GW" ]; then break; fi
        if validar_ip $GW; then break; else echo "IP Gateway Inválida."; fi
    done

    while true; do
        read -p "DNS (Enter vacio): " DNS
        if [ -z "$DNS" ]; then break; fi
        if validar_ip $DNS; then break; else echo "IP DNS Inválida."; fi
    done

    # APLICAR IP
    echo "Configurando IP estática..."
    CON_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep $INTERFACE | cut -d: -f1)
    if [ -z "$CON_NAME" ]; then CON_NAME=$INTERFACE; fi
    
    nmcli con mod "$CON_NAME" ipv4.addresses "$SERVER_IP/$CIDR" ipv4.method manual >/dev/null 2>&1
    if [ ! -z "$GW" ]; then nmcli con mod "$CON_NAME" ipv4.gateway "$GW" >/dev/null 2>&1; fi
    nmcli con down "$CON_NAME" >/dev/null 2>&1
    nmcli con up "$CON_NAME" >/dev/null 2>&1
    sleep 2

    # GENERAR ARCHIVO
    echo "Generando dhcpd.conf..."
    cat > $DHCP_CONF <<EOF
default-lease-time $LEASE;
max-lease-time $LEASE;
authoritative;

subnet $SUBNET_ID netmask $MASK {
  range $RANGE_START $RANGE_END;
EOF
    if [ ! -z "$GW" ]; then echo "  option routers $GW;" >> $DHCP_CONF; fi
    if [ ! -z "$DNS" ]; then echo "  option domain-name-servers $DNS;" >> $DHCP_CONF; fi
    echo "}" >> $DHCP_CONF

    # REINICIAR SERVICIOS
    systemctl enable dhcpd >/dev/null 2>&1
    systemctl restart dhcpd
    if [ $? -eq 0 ]; then
        echo "¡Servicio DHCP iniciado EXITOSAMENTE!"
    else
        echo "ERROR: El servicio falló. Revisa 'journalctl -u dhcpd'"
    fi
    
    firewall-cmd --add-service=dhcp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    pause
}

function monitorear() {
    clear
    echo "=== MONITOREO ==="
    systemctl status dhcpd --no-pager | grep Active
    echo "--- Leases ---"
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        grep "lease" /var/lib/dhcpd/dhcpd.leases
    else
        echo "Sin leases."
    fi
    pause
}

# --- VARIABLES ---
INTERFACE="enp0s8"
DHCP_CONF="/etc/dhcp/dhcpd.conf"

# --- MENU ---
function menu_dhcp() {
	while true; do
    	clear
    	echo "MENU ALMALINUX DHCP"
    	echo "1. Instalar"
    	echo "2. Verificar"
    	echo "3. Configurar"
    	echo "4. Monitorear"
    	echo "5. Submenu DNS"
    	echo "6. Salir"
    	read -p "Opción: " op
    	case $op in
        	1) instalar_dhcp ;;
        	2) verificar_instalacion ;;
        	3) configurar_dhcp ;;
        	4) monitorear ;;
		5) menu_dns ;;
        	6) return 0 ;;
    	esac
	done
}

menu_dhcp()