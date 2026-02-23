#!/bin/bash

# GESTOR DE SERVICIOS

#IMPORTAR BIBLIOTECAS
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

source "$SCRIPT_DIR/ssh_funciones.sh"
source "$SCRIPT_DIR/dhcp_funciones.sh"
source "$SCRIPT_DIR/funciones_dns.sh"

# 2. FUNCIONES AUXILIARES LOCALES
function mostrar_encabezado() {
    clear
    echo "=========================================="
    echo "       MENU PRINCIPAL DE SERVICIOS"
    echo "=========================================="
    echo " Usuario: $(whoami) | Host: $(hostname)"
    echo "=========================================="
}

# 3. MENÚ PRINCIPAL (Punto de entrada único)
function menu_principal() {
    # Validar que se ejecute como root antes de empezar
    if [[ $EUID -ne 0 ]]; then
       echo "Este script debe ser ejecutado como root." 
       exit 1
    fi

    while true; do
        mostrar_encabezado
        echo "1. Implementar/Asegurar SSH (Acceso Remoto)"
        echo "2. Configurar Servicio DHCP (Refactorizado)"
        echo "3. Monitorear Estado de Red"
        echo "4. Salir"
        echo "------------------------------------------"
        read -p "Seleccione una opción [1-4]: " opcion

        case $opcion in
            1)
                # Llama a la función dentro de ssh_functions.sh
                instalar_asegurar_ssh 
                read -p "Presione Enter para volver..."
                ;;
            2)
                # Llama a la función dentro de dhcp_functions.sh
                if declare -f menu_dhcp > /dev/null; then
                    menu_dhcp
                else
                    echo "Error: Función menu_dhcp no cargada."
                fi
                read -p "Presione Enter para volver..."
                ;;
            3)
                echo "Estado de interfaces:"
                ip -brief addr
                read -p "Presione Enter para volver..."
                ;;
            4)
                echo "Saliendo del sistema..."
                exit 0
                ;;
            *)
                echo "Opción no válida, intente de nuevo."
                sleep 1
                ;;
        esac
    done
}

# Ejecución del menú
menu_principal