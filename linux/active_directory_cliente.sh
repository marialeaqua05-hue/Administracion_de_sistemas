#!/bin/bash
# ============================================================
# Archivo: unir_dominio.sh
# Practica 8 - Unir cliente Linux al dominio reprobados.com
# Compatible con: Lubuntu / Ubuntu / AlmaLinux
# ============================================================

DOMINIO="reprobados.com"
DOMINIO_UPPER="REPROBADOS.COM"
DC_IP="192.168.100.20"
ADMIN_USER="Administrador"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Ejecuta como root: sudo bash unir_dominio.sh"
    exit 1
fi

echo "========================================="
echo " UNION AL DOMINIO: $DOMINIO"
echo "========================================="

# 1. Configurar DNS apuntando al DC y a Google para descargar paquetes
echo "[*] Configurando DNS..."
cat > /etc/resolv.conf << EOF
nameserver $DC_IP
nameserver 8.8.8.8
search $DOMINIO
EOF
chattr +i /etc/resolv.conf 2>/dev/null
echo "[OK] DNS configurado."

# 2. Sincronizar tiempo con el DC (requerido por Kerberos)
echo "[*] Sincronizando tiempo..."
if command -v timedatectl &>/dev/null; then
    timedatectl set-ntp true
fi
if command -v chronyc &>/dev/null; then
    chronyc makestep
elif command -v ntpdate &>/dev/null; then
    ntpdate -u $DC_IP 2>/dev/null
fi

# 3. Instalar paquetes necesarios
echo "[*] Instalando paquetes: realmd, sssd, adcli, krb5..."
if command -v apt &>/dev/null; then
    # Ubuntu / Lubuntu
    apt install -yq realmd sssd sssd-tools adcli krb5-user samba-common-bin packagekit oddjob oddjob-mkhomedir
elif command -v dnf &>/dev/null; then
    # AlmaLinux / RHEL
    dnf install -yq realmd sssd sssd-tools adcli krb5-workstation samba-common-tools oddjob oddjob-mkhomedir
fi
echo "[OK] Paquetes instalados."

# 4. Descubrir el dominio
echo "[*] Descubriendo dominio $DOMINIO..."
realm discover $DOMINIO
if [ $? -ne 0 ]; then
    echo "[!] No se pudo descubrir el dominio. Verifica conectividad con $DC_IP"
    exit 1
fi

# 5. Unirse al dominio
echo "[*] Uniendose al dominio $DOMINIO..."
echo "Ingresa la contrasena del Administrador del dominio:"
realm join --user=$ADMIN_USER $DOMINIO
if [ $? -ne 0 ]; then
    echo "[!] Error al unirse al dominio."
    exit 1
fi
echo "[OK] Unido al dominio $DOMINIO."

# 6. Configurar sssd.conf
echo "[*] Configurando sssd.conf..."
cat > /etc/sssd/sssd.conf << EOF
[sssd]
domains = $DOMINIO
config_file_version = 2
services = nss, pam

[domain/$DOMINIO]
ad_domain = $DOMINIO
krb5_realm = $DOMINIO_UPPER
realmd_tags = manages-system joined-with-adcli
cache_credentials = True
id_provider = ad
fallback_homedir = /home/%u@%d
default_shell = /bin/bash
ldap_id_mapping = True
use_fully_qualified_names = True
deny_access_order = deny, allow
ad_gpo_access_control = permissive
EOF

chmod 600 /etc/sssd/sssd.conf
systemctl enable --now sssd
systemctl restart sssd
echo "[OK] sssd configurado."

# 7. Habilitar creacion automatica de home directory
echo "[*] Habilitando pam_mkhomedir..."
if command -v pam-auth-update &>/dev/null; then
    pam-auth-update --enable mkhomedir
else
    authselect select sssd with-mkhomedir --force 2>/dev/null || \
    echo "session required pam_mkhomedir.so" >> /etc/pam.d/common-session
fi
echo "[OK] Home directory automatico habilitado."

# 8. Permisos sudo para usuarios de AD
echo "[*] Configurando sudo para usuarios del dominio..."
cat > /etc/sudoers.d/ad-admins << EOF
# Usuarios del dominio reprobados.com con sudo
%Cuates@$DOMINIO ALL=(ALL) ALL
%Domain\ Admins@$DOMINIO ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/ad-admins
echo "[OK] Sudo configurado para grupos del dominio."

# 9. Verificacion
echo ""
echo "========================================="
echo " VERIFICACION"
echo "========================================="
realm list
echo ""
echo "[*] Probando resolucion de usuario AD..."
id "jgarcia@$DOMINIO" 2>/dev/null && echo "[OK] Usuario jgarcia encontrado en AD" || echo "[!] Usuario no encontrado - verifica que AD tenga usuarios"

echo ""
echo "[OK] Union al dominio completada."
echo "     Puedes iniciar sesion con: jgarcia@$DOMINIO"
echo "     Contrasena: Pass1234!"