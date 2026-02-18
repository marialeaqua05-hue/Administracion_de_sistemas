#!/bin/bash

# ==============================================================================
# MENU PRINCIPAL DNS
# Archivo: main_dns.sh
# ==============================================================================

# Cargar Librería
SCRIPT_DIR=$(dirname "$0")
# Aseguramos que busque el nombre correcto que tienes tú: funciones_dns.sh
LIB_FILE="$SCRIPT_DIR/funciones_dns.sh"

if [ -f "$LIB_FILE" ]; then
    source "$LIB_FILE"
else
    echo "ERROR: No encuentro $LIB_FILE en la misma carpeta."
    echo "Verifica que el archivo de funciones esté ahí."
    exit 1
fi

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
            6) exit 0 ;;            # Regresa al menú DHCP
            *) echo "Opción inválida"; sleep 1 ;;
        esac
    done
}

# Ejecutar el menú
menu_dns