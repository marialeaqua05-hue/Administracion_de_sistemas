#!/bin/bash

# GESTOR DE SERVICIOS

#IMPORTAR BIBLIOTECAS
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

source "$SCRIPT_DIR/ssh_funciones.sh"
source "$SCRIPT_DIR/dhcp_funciones.sh"
source "$SCRIPT_DIR/funciones_dns.sh"
source "$SCRIPT_DIR/ftp.sh"
source "$SCRIPT_DIR/http.sh"
source "$SCRIPT_DIR/dockers.sh"

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
    if [[ $EUID -ne 0 ]]; then
       echo "Este script debe ser ejecutado como root." 
       exit 1
    fi

    while true; do
        mostrar_encabezado
        echo "1. Implementar/Asegurar SSH (Acceso Remoto)"
        echo "2. Configurar Servicio DHCP"
        echo "3. Monitorear Estado de Red"
        echo "4. Gestion FTP"
        echo "5. Aprovisionamiento Web HTTP (Apache/Nginx/Tomcat)"
	echo "6. Virtualización nativa, persistencia y seguridad en Dockers"
        echo "0. Salir"
        echo "------------------------------------------"
        read -p "Seleccione una opción [0-6]: " opcion

        case $opcion in
            1)
                instalar_asegurar_ssh
                read -p "Presione Enter para volver..."
                ;;
            2)
                if declare -f menu_dhcp > /dev/null; then
                    menu_dhcp
                else
                    echo "Error: Función menu_dhcp no cargada."
                    read -p "Presione Enter para volver..."
                fi
                ;;
            3)
                echo "Estado de interfaces:"
                ip -brief addr
                read -p "Presione Enter para volver..."
                ;;
            4)
                if declare -f menu_ftp > /dev/null; then
                    menu_ftp
                else
                    echo "Error: Función menu_ftp no cargada."
                    read -p "Presione Enter para volver..."
                fi
                ;;
            5)
                if declare -f menu_http > /dev/null; then
                    menu_http
                else
                    echo "Error: Función menu_http no cargada."
                    read -p "Presione Enter para volver..."
                fi
                ;;
	    6)
		if declare -f menu_dockers > /dev/null; then
		   menu_dockers
		else
		   echo "Error: Función menu_dockers no cargada."
		   read -p "Presione Enter para volver..."
		fi
		;;
            0)
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