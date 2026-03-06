#!/bin/bash

# --- PRE-REQUISITOS ---
if [ "$EUID" -ne 0 ]; then
  echo "[!] Por favor ejecuta este script como root (sudo)."
  exit 1
fi

# Variables Globales
BASE_DIR="/srv/ftp_global"
ANON_DIR="/srv/ftp_anon"

# 1. INSTALACIÓN E IDEMPOTENCIA
instalar_ftp() {
    clear
    echo "========================================="
    echo " 1. INSTALANDO Y CONFIGURANDO VSFTPD"
    echo "========================================="

    # Instalación de paquetes
    dnf install -y vsftpd policycoreutils-python-utils

    # Creación de Grupos
    groupadd -f reprobados
    groupadd -f recursadores
    groupadd -f ftp_auth # Grupo extra para darles permisos a la carpeta general

    # Crear estructura física real de carpetas
    echo "[*] Creando estructura de directorios base..."
    mkdir -p $BASE_DIR/{general,reprobados,recursadores,personal}
    mkdir -p $ANON_DIR/general

    # Asignar Permisos y Propietarios (ACLs y Chmod)
    # General: Root es dueño, ftp_auth puede escribir, otros (anónimos) solo leen
    chown root:ftp_auth $BASE_DIR/general
    chmod 775 $BASE_DIR/general

    # Grupos: Solo root y los miembros del grupo pueden acceder/escribir
    chown root:reprobados $BASE_DIR/reprobados
    chmod 770 $BASE_DIR/reprobados

    chown root:recursadores $BASE_DIR/recursadores
    chmod 770 $BASE_DIR/recursadores

    # Configuración de vsftpd.conf
    echo "[*] Configurando /etc/vsftpd/vsftpd.conf..."
    cp /etc/vsftpd/vsftpd.conf /etc/vsftpd/vsftpd.conf.bak
    
    cat > /etc/vsftpd/vsftpd.conf <<EOF
anonymous_enable=YES
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_std_format=YES
listen=NO
listen_ipv6=YES
pam_service_name=vsftpd
userlist_enable=YES

# Configuracion de la Prision (Chroot)
chroot_local_user=YES
allow_writeable_chroot=NO
local_root=/home/\$USER/ftp

# Configuracion Anonima
anon_root=$ANON_DIR
no_anon_password=YES
EOF

    # Montar la carpeta general para el usuario anónimo
    if ! grep -q "$BASE_DIR/general $ANON_DIR/general" /etc/fstab; then
        mount --bind $BASE_DIR/general $ANON_DIR/general
        echo "$BASE_DIR/general $ANON_DIR/general none bind 0 0" >> /etc/fstab
    fi

    # Configurar Firewall
    echo "[*] Abriendo puertos en el Firewall..."
    firewall-cmd --permanent --add-service=ftp
    firewall-cmd --reload

    # Configurar SELinux (CRÍTICO en AlmaLinux)
    echo "[*] Configurando políticas de SELinux para FTP..."
    setsebool -P ftpd_full_access 1
    
    # Iniciar Servicio
    systemctl enable --now vsftpd

    echo -e "\n[OK] Servicio vsftpd instalado y configurado correctamente."
    read -p "Presiona Enter para continuar..."
}

# 2. GESTIÓN AUTOMATIZADA DE USUARIOS
crear_usuarios() {
    clear
    echo "========================================="
    echo " 2. CREACIÓN MASIVA DE USUARIOS"
    echo "========================================="
    
    read -p "¿Cuántos usuarios deseas crear?: " num_users

    if ! [[ "$num_users" =~ ^[0-9]+$ ]]; then
        echo "Por favor ingresa un número válido."
        sleep 2; return
    fi

    for (( i=1; i<=num_users; i++ ))
    do
        echo -e "\n--- Usuario $i de $num_users ---"
        read -p "Nombre de usuario: " username
        read -s -p "Contraseña: " password; echo
        
        # Validar grupo
        while true; do
            read -p "Grupo (reprobados / recursadores): " usergroup
            if [[ "$usergroup" == "reprobados" || "$usergroup" == "recursadores" ]]; then
                break
            else
                echo "Grupo inválido. Escribe 'reprobados' o 'recursadores'."
            fi
        done

        # 1. Crear el usuario en Linux
        useradd -m -g $usergroup -G ftp_auth "$username"
        echo "$username:$password" | chpasswd

        # 2. Crear la "cárcel" FTP del usuario (NO debe tener permisos de escritura por seguridad vsftpd)
        mkdir -p /home/$username/ftp
        chown root:root /home/$username/ftp
        chmod 755 /home/$username/ftp

        # 3. Crear las carpetas de vista dentro de la cárcel
        mkdir -p /home/$username/ftp/{general,$usergroup,$username}

        # 4. Crear su carpeta personal física real
        mkdir -p $BASE_DIR/personal/$username
        chown $username:$usergroup $BASE_DIR/personal/$username
        chmod 700 $BASE_DIR/personal/$username

        # 5. Aplicar los Mount Binds (Espejos)
        mount --bind $BASE_DIR/general /home/$username/ftp/general
        mount --bind $BASE_DIR/$usergroup /home/$username/ftp/$usergroup
        mount --bind $BASE_DIR/personal/$username /home/$username/ftp/$username

        # 6. Hacer los montajes persistentes en /etc/fstab (marcados para fácil borrado)
        echo "$BASE_DIR/general /home/$username/ftp/general none bind 0 0 #FTP_$username" >> /etc/fstab
        echo "$BASE_DIR/$usergroup /home/$username/ftp/$usergroup none bind 0 0 #FTP_$username" >> /etc/fstab
        echo "$BASE_DIR/personal/$username /home/$username/ftp/$username none bind 0 0 #FTP_$username" >> /etc/fstab

        echo "[OK] Usuario $username creado y enjaulado exitosamente."
    done
    read -p "Presiona Enter para continuar..."
}

# 3. CAMBIO DE GRUPO DINÁMICO
cambiar_grupo() {
    clear
    echo "========================================="
    echo " 3. CAMBIAR GRUPO DE USUARIO"
    echo "========================================="
    
    read -p "Nombre del usuario: " username
    
    if ! id "$username" &>/dev/null; then
        echo "El usuario $username no existe."
        sleep 2; return
    fi

    # Detectar grupo actual
    old_group=$(id -gn $username)
    
    if [[ "$old_group" != "reprobados" && "$old_group" != "recursadores" ]]; then
        echo "El usuario no pertenece a los grupos gestionados."
        sleep 2; return
    fi

    echo "El usuario $username está actualmente en: $old_group"
    read -p "Nuevo grupo (reprobados / recursadores): " new_group

    if [[ "$new_group" != "reprobados" && "$new_group" != "recursadores" || "$new_group" == "$old_group" ]]; then
        echo "Grupo inválido o es el mismo grupo actual."
        sleep 2; return
    fi

    # 1. Desmontar la carpeta del grupo viejo
    umount /home/$username/ftp/$old_group
    rmdir /home/$username/ftp/$old_group

    # 2. Cambiar al usuario de grupo en el sistema y cambiar dueño de su personal
    usermod -g $new_group $username
    chown $username:$new_group $BASE_DIR/personal/$username

    # 3. Crear la nueva carpeta y montarla
    mkdir -p /home/$username/ftp/$new_group
    mount --bind $BASE_DIR/$new_group /home/$username/ftp/$new_group

    # 4. Actualizar el archivo fstab eliminando la línea vieja y agregando la nueva
    sed -i "\|\/home/$username/ftp/$old_group|d" /etc/fstab
    echo "$BASE_DIR/$new_group /home/$username/ftp/$new_group none bind 0 0 #FTP_$username" >> /etc/fstab

    echo "[OK] Usuario $username transferido exitosamente a $new_group."
    read -p "Presiona Enter para continuar..."
}

# =========================================================================
# MENÚ PRINCIPAL FTP
# =========================================================================
menu_ftp() {
    while true; do
        clear
        echo "========================================="
        echo "   PANEL DE GESTIÓN FTP (VSFTPD) LINUX   "
        echo "========================================="
        echo " [ 1 ] Instalar y configurar Servidor FTP"
        echo " [ 2 ] Crear usuarios masivamente"
        echo " [ 3 ] Cambiar usuario de grupo"
        echo " [ 0 ] Regresar al Panel Central"
        echo "========================================="
        read -p "Selecciona una opción: " opcion

        case $opcion in
            1) instalar_ftp ;;
            2) crear_usuarios ;;
            3) cambiar_grupo ;;
            0) return ;; # Usamos return en lugar de exit para no cerrar main_bash.sh
            *) echo "Opción no válida."; sleep 1 ;;
        esac
    done
}