#!/bin/bash

function instalar_asegurar_ssh() {
    echo "--- Configurando SSH ---"
    
    #Se instala ssh (server)
    sudo dnf install -y openssh-server
    
    # Habilitamos el arranque
    sudo systemctl enable --now sshd
    
    #Configurar firewall
    sudo firewall-cmd --permanent --add-service=ssh
    sudo firewall-cmd --reload
    
    echo "SSH configurado exitosamente. Ya puede desconectar la consola física."
}

function validar_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: Este script debe ejecutarse como root."
        exit 1
    fi
}