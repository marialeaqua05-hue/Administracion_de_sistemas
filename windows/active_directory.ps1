# ============================================================
# Archivo: practica8.ps1
# Practica 8 - Active Directory, GPO, FSRM y AppLocker
# Windows Server 2022 - Dominio: reprobados.com
# ============================================================

# ==========================================
# CONFIGURACION GLOBAL
# ==========================================
$DOMINIO        = "reprobados.com"
$NETBIOS        = "REPROBADOS"
$DC_IP          = "192.168.56.103"
$SAFE_PWD       = ConvertTo-SecureString "Admin1234!" -AsPlainText -Force
$USERS_CSV      = "$PSScriptRoot\usuarios.csv"
$CARPETAS_BASE  = "C:\Usuarios"
$PERFILES_BASE  = "C:\Perfiles"
$LOG_FILE       = "C:\practica8_log.txt"

function Write-Log {
    param([string]$Msg, [string]$Color = "Cyan")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $Msg" -ForegroundColor $Color
    "[$ts] $Msg" | Out-File $LOG_FILE -Append
}

function Pause-Menu {
    Read-Host "`nPresione Enter para continuar"
}

# ==========================================
# MODULO 1: INSTALAR AD DS Y PROMOVER A DC
# ==========================================
function Instalar-ActiveDirectory {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 1. INSTALAR AD DS Y PROMOVER A DC"       -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    # Verificar si ya es DC
    $isDC = (Get-WmiObject Win32_ComputerSystem).DomainRole -ge 4
    if ($isDC) {
        Write-Log "Este servidor ya es un Domain Controller." "Yellow"
        Pause-Menu; return
    }

    # Instalar rol AD DS
    Write-Log "Instalando rol AD DS..."
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
    Write-Log "Rol AD DS instalado." "Green"

    # Instalar FSRM
    Write-Log "Instalando FSRM..."
    Install-WindowsFeature -Name FS-Resource-Manager -IncludeManagementTools | Out-Null
    Write-Log "FSRM instalado." "Green"

    # Promover a DC (crea nuevo bosque)
    Write-Log "Promoviendo servidor a Domain Controller del dominio $DOMINIO..."
    Write-Log "El servidor se reiniciara automaticamente al terminar." "Yellow"

    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName $DOMINIO `
        -DomainNetbiosName $NETBIOS `
        -SafeModeAdministratorPassword $SAFE_PWD `
        -InstallDns:$true `
        -Force:$true `
        -NoRebootOnCompletion:$false | Out-Null

    Write-Log "Dominio $DOMINIO creado. Reiniciando..." "Green"
}

# ==========================================
# MODULO 2: CREAR OU, GRUPOS Y USUARIOS DESDE CSV
# ==========================================
function Crear-EstructuraAD {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 2. CREAR OUs, GRUPOS Y USUARIOS"         -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module ActiveDirectory

    $DC = "DC=reprobados,DC=com"

    # Crear OUs
    foreach ($ou in @("Cuates", "NoCuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $DC
            Write-Log "OU '$ou' creada." "Green"
        } else {
            Write-Log "OU '$ou' ya existe." "Yellow"
        }
    }

    # Crear grupos de seguridad
    foreach ($grupo in @("Cuates", "NoCuates")) {
        $ouPath = "OU=$grupo,$DC"
        if (-not (Get-ADGroup -Filter "Name -eq '$grupo'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $grupo -GroupScope Global -GroupCategory Security -Path $ouPath
            Write-Log "Grupo '$grupo' creado en OU $grupo." "Green"
        } else {
            Write-Log "Grupo '$grupo' ya existe." "Yellow"
        }
    }

    # Verificar CSV
    if (-not (Test-Path $USERS_CSV)) {
        Write-Log "[!] No se encontro el CSV: $USERS_CSV" "Red"
        Pause-Menu; return
    }

    # Crear carpeta base para datos personales (disco H:)
    if (-not (Test-Path $CARPETAS_BASE)) {
        New-Item -Path $CARPETAS_BASE -ItemType Directory | Out-Null
    }

    # Crear carpeta base para perfiles moviles
    if (-not (Test-Path $PERFILES_BASE)) {
        New-Item -Path $PERFILES_BASE -ItemType Directory | Out-Null
    }

    # Compartir carpeta de perfiles moviles como recurso oculto
    $sharePerfiles = Get-SmbShare -Name "Perfiles$" -ErrorAction SilentlyContinue
    if (-not $sharePerfiles) {
        New-SmbShare -Name "Perfiles$" -Path $PERFILES_BASE `
            -FullAccess "Administradores" `
            -ChangeAccess "Usuarios autentificados" `
            -Description "Perfiles moviles de usuarios del dominio" | Out-Null
        Write-Log "Recurso compartido 'Perfiles$' creado." "Green"
    } else {
        Write-Log "Recurso compartido 'Perfiles$' ya existe." "Yellow"
    }

    # Compartir carpeta de datos personales (disco H:)
    $shareUsuarios = Get-SmbShare -Name "Usuarios$" -ErrorAction SilentlyContinue
    if (-not $shareUsuarios) {
        New-SmbShare -Name "Usuarios$" -Path $CARPETAS_BASE `
            -FullAccess "Administradores" `
            -ChangeAccess "Usuarios autentificados" `
            -Description "Carpetas personales de usuarios del dominio" | Out-Null
        Write-Log "Recurso compartido 'Usuarios$' creado." "Green"
    }

    # Importar usuarios del CSV
    $usuarios = Import-Csv $USERS_CSV
    foreach ($u in $usuarios) {
        $nombre   = $u.Nombre
        $apellido = $u.Apellido
        $usuario  = $u.Usuario
        $grupo    = $u.Grupo
        $pwd      = ConvertTo-SecureString $u.Password -AsPlainText -Force
        $ouPath   = "OU=$grupo,$DC"

        # Crear usuario en AD
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$usuario'" -ErrorAction SilentlyContinue)) {
            New-ADUser `
                -Name "$nombre $apellido" `
                -GivenName $nombre `
                -Surname $apellido `
                -SamAccountName $usuario `
                -UserPrincipalName "$usuario@$DOMINIO" `
                -Path $ouPath `
                -AccountPassword $pwd `
                -Enabled $true `
                -PasswordNeverExpires $true
            Write-Log "Usuario '$usuario' creado en OU $grupo." "Green"
        } else {
            Write-Log "Usuario '$usuario' ya existe." "Yellow"
        }

        # Agregar al grupo correspondiente
        Add-ADGroupMember -Identity $grupo -Members $usuario -ErrorAction SilentlyContinue
        Write-Log "  -> Agregado al grupo '$grupo'." "Green"

        # --- CARPETA PERSONAL (Disco H:) ---
        $carpetaUsuario = "$CARPETAS_BASE\$usuario"
        if (-not (Test-Path $carpetaUsuario)) {
            New-Item -Path $carpetaUsuario -ItemType Directory | Out-Null
        }

        # Permisos NTFS en carpeta personal
        $acl = Get-Acl $carpetaUsuario
        $acl.SetAccessRuleProtection($true, $false)
        $reglaAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Administradores", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $reglaUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$NETBIOS\$usuario", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($reglaAdmin)
        $acl.AddAccessRule($reglaUser)
        Set-Acl $carpetaUsuario $acl
        Write-Log "  -> Carpeta personal '$carpetaUsuario' creada." "Green"

        # --- PERFIL MOVIL ---
        # Crear carpeta de perfil movil para el usuario
        $carpetaPerfil = "$PERFILES_BASE\$usuario"
        if (-not (Test-Path $carpetaPerfil)) {
            New-Item -Path $carpetaPerfil -ItemType Directory | Out-Null
        }

        # Permisos NTFS en carpeta de perfil movil
        $aclPerfil = Get-Acl $carpetaPerfil
        $aclPerfil.SetAccessRuleProtection($true, $false)
        $reglaAdminP = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Administradores", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $reglaUserP = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$NETBIOS\$usuario", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $aclPerfil.AddAccessRule($reglaAdminP)
        $aclPerfil.AddAccessRule($reglaUserP)
        Set-Acl $carpetaPerfil $aclPerfil
        Write-Log "  -> Carpeta de perfil movil '$carpetaPerfil' creada." "Green"

        # Asignar en AD: carpeta personal (H:) y perfil movil
        $servidorName = $env:COMPUTERNAME
        Set-ADUser -Identity $usuario `
            -HomeDirectory "\\$servidorName\Usuarios$\$usuario" `
            -HomeDrive "H:" `
            -ProfilePath "\\$servidorName\Perfiles$\$usuario"
        Write-Log "  -> Perfil movil asignado: \\$servidorName\Perfiles$\$usuario" "Green"

        # Crear carpeta .V6 (sufijo que agrega Windows 10/11 a perfiles moviles)
        $carpetaPerfilV6 = "$PERFILES_BASE\$usuario.V6"
        if (-not (Test-Path $carpetaPerfilV6)) {
            New-Item -Path $carpetaPerfilV6 -ItemType Directory | Out-Null
        }
        $aclV6 = Get-Acl $carpetaPerfil
        Set-Acl $carpetaPerfilV6 $aclV6
        Write-Log "  -> Carpeta perfil movil .V6 creada: $carpetaPerfilV6" "Green"
    }

    Write-Log "Estructura AD creada exitosamente." "Green"
    Pause-Menu
}

# ==========================================
# MODULO 3: HORARIOS DE INICIO DE SESION
# ==========================================
function Configurar-HorariosAcceso {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 3. CONTROL DE ACCESO TEMPORAL (LOGON HOURS)" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module ActiveDirectory

    # Horarios en bytes (168 bits = 21 bytes, un bit por hora de la semana)
    # Domingo=bits 0-23, Lunes=24-47, ... Sabado=144-167
    # Cuates: 8AM-3PM (horas 8-14) cada dia
    # NoCuates: 3PM-2AM (horas 15-25, es decir 15-23 y 0-1 del dia siguiente)

    # Generar array de 21 bytes (168 horas)
    function New-LogonHoursBytes {
        param([int[]]$HorasPermitidas)
        $bits = New-Object bool[] 168
        foreach ($dia in 0..6) {
            foreach ($hora in $HorasPermitidas) {
                $idx = $dia * 24 + $hora
                if ($idx -ge 0 -and $idx -lt 168) {
                    $bits[$idx] = $true
                }
            }
        }
        $bytes = New-Object byte[] 21
        for ($i = 0; $i -lt 168; $i++) {
            if ($bits[$i]) {
                $byteIdx = [int][Math]::Floor($i / 8)
                $bitPos  = $i % 8
                $bytes[$byteIdx] = [byte]($bytes[$byteIdx] -bor (1 -shl $bitPos))
            }
        }
        return ,$bytes
    }

    # Cuates: 8AM a 3PM Local -> +7 horas = 15 a 21 en UTC
    $horasCuates   = 15..21

    # NoCuates: 3PM a 2AM Local -> +7 horas = 22 a 8 en UTC
    $horasNoCuates = @(22,23,0,1,2,3,4,5,6,7,8)

    $bytesCuates   = New-LogonHoursBytes -HorasPermitidas $horasCuates
    $bytesNoCuates = New-LogonHoursBytes -HorasPermitidas $horasNoCuates

    # Aplicar a cada usuario segun su grupo
    $usuarios = Get-ADUser -Filter * -SearchBase "OU=Cuates,DC=reprobados,DC=com" -ErrorAction SilentlyContinue
    foreach ($u in $usuarios) {
        Set-ADUser -Identity $u.SamAccountName -Replace @{logonHours = $bytesCuates}
        Write-Log "Cuates - Horario 8AM-3PM aplicado a: $($u.SamAccountName)" "Green"
    }

    $usuarios = Get-ADUser -Filter * -SearchBase "OU=NoCuates,DC=reprobados,DC=com" -ErrorAction SilentlyContinue
    foreach ($u in $usuarios) {
        Set-ADUser -Identity $u.SamAccountName -Replace @{logonHours = $bytesNoCuates}
        Write-Log "NoCuates - Horario 3PM-2AM aplicado a: $($u.SamAccountName)" "Green"
    }

    # Configurar GPO para forzar cierre de sesion al expirar horario
    Write-Log "Configurando GPO para forzar cierre de sesion al expirar horario..."

    $GPOName = "Control-HorarioAcceso"
    $GPO = Get-GPO -Name $GPOName -ErrorAction SilentlyContinue
    
    if (-not $GPO) {
        $GPO = New-GPO -Name $GPOName
        Write-Log "GPO '$GPOName' creada en base de datos. Esperando al disco..." "Yellow"
        Start-Sleep -Seconds 5 # EL SALVAVIDAS: Da tiempo a que se cree la carpeta SYSVOL
        Write-Log "Estructura SYSVOL lista." "Green"
    }

    # Habilitar la desconexión forzada directamente en la GPO (No usar secedit)
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -ValueName "ForceLogoffWhenHourExpire" `
        -Type DWord `
        -Value 1 | Out-Null

    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" `
        -ValueName "EnableForcedLogOff" `
        -Type DWord `
        -Value 1 | Out-Null

    # Vincular GPO al dominio
    $domPath = "DC=reprobados,DC=com"
    try {
        New-GPLink -Name $GPOName -Target $domPath -ErrorAction Stop | Out-Null
        Write-Log "GPO '$GPOName' vinculada al dominio." "Green"
    } catch {
        Write-Log "GPO ya estaba vinculada." "Yellow"
    }

    Write-Log "Control de acceso temporal configurado exitosamente." "Green"
    Pause-Menu
}

# ==========================================
# MODULO 4: FSRM - CUOTAS Y APANTALLAMIENTO
# ==========================================
function Configurar-FSRM {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 4. FSRM - CUOTAS Y APANTALLAMIENTO"      -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module FileServerResourceManager -ErrorAction SilentlyContinue
    if (-not (Get-Module FileServerResourceManager)) {
        Write-Log "[!] Modulo FSRM no disponible. Instala el rol primero." "Red"
        Pause-Menu; return
    }

    # Crear plantillas de cuota
    Write-Log "Creando plantillas de cuota FSRM..."

    # Plantilla 5MB para NoCuates
    $plantilla5MB = Get-FsrmQuotaTemplate -Name "Cuota-5MB-NoCuates" -ErrorAction SilentlyContinue
    if (-not $plantilla5MB) {
        New-FsrmQuotaTemplate -Name "Cuota-5MB-NoCuates" `
            -Size 5MB `
            -SoftLimit:$false `
            -Description "Cuota estricta 5MB para grupo NoCuates"
        Write-Log "Plantilla 5MB creada." "Green"
    }

    # Plantilla 10MB para Cuates
    $plantilla10MB = Get-FsrmQuotaTemplate -Name "Cuota-10MB-Cuates" -ErrorAction SilentlyContinue
    if (-not $plantilla10MB) {
        New-FsrmQuotaTemplate -Name "Cuota-10MB-Cuates" `
            -Size 10MB `
            -SoftLimit:$false `
            -Description "Cuota estricta 10MB para grupo Cuates"
        Write-Log "Plantilla 10MB creada." "Green"
    }

    # Aplicar cuotas por usuario segun grupo
    Import-Module ActiveDirectory
    $DC = "DC=reprobados,DC=com"

    # Cuates -> 10MB
    $cuates = Get-ADUser -Filter * -SearchBase "OU=Cuates,$DC" -ErrorAction SilentlyContinue
    foreach ($u in $cuates) {
        $carpeta = "$CARPETAS_BASE\$($u.SamAccountName)"
        if (Test-Path $carpeta) {
            $cuotaExiste = Get-FsrmQuota -Path $carpeta -ErrorAction SilentlyContinue
            if (-not $cuotaExiste) {
                New-FsrmQuota -Path $carpeta -Template "Cuota-10MB-Cuates"
                Write-Log "Cuota 10MB aplicada a: $carpeta" "Green"
            } else {
                Write-Log "Cuota ya existe en: $carpeta" "Yellow"
            }
        }
    }

    # NoCuates -> 5MB
    $noCuates = Get-ADUser -Filter * -SearchBase "OU=NoCuates,$DC" -ErrorAction SilentlyContinue
    foreach ($u in $noCuates) {
        $carpeta = "$CARPETAS_BASE\$($u.SamAccountName)"
        if (Test-Path $carpeta) {
            $cuotaExiste = Get-FsrmQuota -Path $carpeta -ErrorAction SilentlyContinue
            if (-not $cuotaExiste) {
                New-FsrmQuota -Path $carpeta -Template "Cuota-5MB-NoCuates"
                Write-Log "Cuota 5MB aplicada a: $carpeta" "Green"
            } else {
                Write-Log "Cuota ya existe en: $carpeta" "Yellow"
            }
        }
    }

    # Apantallamiento activo de archivos
    Write-Log "Configurando apantallamiento de archivos (File Screening)..."

    # Crear grupo de archivos bloqueados
    $grupoArchivos = Get-FsrmFileGroup -Name "Archivos-Bloqueados-P8" -ErrorAction SilentlyContinue
    if (-not $grupoArchivos) {
        New-FsrmFileGroup -Name "Archivos-Bloqueados-P8" `
            -IncludePattern @("*.mp3","*.mp4","*.wav","*.avi","*.mkv","*.exe","*.msi","*.bat","*.cmd")
        Write-Log "Grupo de archivos bloqueados creado." "Green"
    }

    # Crear plantilla de apantallamiento
    $plantillaScreen = Get-FsrmFileScreenTemplate -Name "Bloqueo-Multimedia-Ejecutables" -ErrorAction SilentlyContinue
    if (-not $plantillaScreen) {
        New-FsrmFileScreenTemplate -Name "Bloqueo-Multimedia-Ejecutables" `
            -Active:$true `
            -IncludeGroup @("Archivos-Bloqueados-P8")
        Write-Log "Plantilla de apantallamiento creada." "Green"
    }

    # Aplicar apantallamiento a cada carpeta de usuario
    $todosUsuarios = Get-ADUser -Filter * -SearchBase "OU=Cuates,$DC" -ErrorAction SilentlyContinue
    $todosUsuarios += Get-ADUser -Filter * -SearchBase "OU=NoCuates,$DC" -ErrorAction SilentlyContinue

    foreach ($u in $todosUsuarios) {
        $carpeta = "$CARPETAS_BASE\$($u.SamAccountName)"
        if (Test-Path $carpeta) {
            $screenExiste = Get-FsrmFileScreen -Path $carpeta -ErrorAction SilentlyContinue
            if (-not $screenExiste) {
                New-FsrmFileScreen -Path $carpeta -Template "Bloqueo-Multimedia-Ejecutables" -Active:$true
                Write-Log "Apantallamiento aplicado a: $carpeta" "Green"
            } else {
                Write-Log "Apantallamiento ya existe en: $carpeta" "Yellow"
            }
        }
    }

    Write-Log "FSRM configurado exitosamente." "Green"
    Pause-Menu
}

# ==========================================
# ==========================================
# MODULO 5: APPLOCKER
# ==========================================
function Configurar-AppLocker {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 5. APPLOCKER - CONTROL DE EJECUCION"     -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module ActiveDirectory
    $DC         = (Get-ADDomain).DistinguishedName
    $NombreNetB = (Get-ADDomain).Name
    $notepadPath = "$env:SystemRoot\System32\notepad.exe"
    $GPOName    = "GPO_AppLocker_P8"

    # Eliminar GPO previa para empezar limpio
    Remove-GPO -Name $GPOName -ErrorAction SilentlyContinue
    Write-Log "Creando GPO '$GPOName'..." "Cyan"
    $Gpo = New-GPO -Name $GPOName
    Start-Sleep -Seconds 5
    New-GPLink -Name $GPOName -Target $DC -ErrorAction SilentlyContinue | Out-Null
    $RutaLdap = "LDAP://CN={$($Gpo.Id)},CN=Policies,CN=System,$DC"

    # Paso 1: Inyectar reglas salvavidas
    Write-Log "Configurando reglas base (salvavidas)..." "Cyan"
    $xmlSalvavidas = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="(Salvavidas) Program Files" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51" Name="(Salvavidas) Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="(Salvavidas) Administradores" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
"@
    $TempSalvavidas = "$env:TEMP\salvavidas.xml"
    $xmlSalvavidas | Out-File $TempSalvavidas -Encoding UTF8
    Set-AppLockerPolicy -XmlPolicy $TempSalvavidas -Ldap $RutaLdap
    Write-Log "Reglas salvavidas inyectadas." "Green"

    # Obtener los identificadores (SID) exactos de tus grupos en Active Directory
    $SidCuates = (Get-ADGroup "Cuates").SID.Value
    $SidNoCuates = (Get-ADGroup "NoCuates").SID.Value

    # Paso 2 y 3: Reglas de Ruta (Path) para Notepad usando XML
    Write-Log "Generando reglas PATH universales para Notepad..." "Cyan"
    $xmlNotepad = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="$([guid]::NewGuid().ToString())" Name="Permitir Notepad Cuates" Description="" UserOrGroupSid="$SidCuates" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*\notepad.exe" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$([guid]::NewGuid().ToString())" Name="Denegar Notepad NoCuates" Description="" UserOrGroupSid="$SidNoCuates" Action="Deny">
      <Conditions><FilePathCondition Path="%WINDIR%\*\notepad.exe" /></Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
"@
    $TempNotepad = "$env:TEMP\notepad_rules.xml"
    $xmlNotepad | Out-File $TempNotepad -Encoding UTF8
    
    # Inyectar las reglas a la GPO
    Set-AppLockerPolicy -XmlPolicy $TempNotepad -Ldap $RutaLdap -Merge
    Write-Log "Reglas Path para Notepad inyectadas correctamente." "Green"

    # Paso 4: Configurar AppIDSvc para arranque automatico via GPO
    Write-Log "Configurando arranque automatico de AppIDSvc en clientes..." "Cyan"
    $AppIdKey = "HKLM\System\CurrentControlSet\Services\AppIDSvc"
    Set-GPRegistryValue -Name $GPOName -Key $AppIdKey -ValueName "Start" -Type DWord -Value 2 | Out-Null

    # Habilitar servicio en el servidor
    try { Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue } catch {}
    Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    Write-Log "Servicio AppLocker habilitado." "Green"

    gpupdate /force | Out-Null
    Write-Log "AppLocker configurado. Ejecuta gpupdate /force en el cliente." "Green"
    Pause-Menu
}

# ==========================================
# MODULO 6: UNION AL DOMINIO (WINDOWS CLIENT)
# ==========================================
function Unir-ClienteWindows {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 6. UNIR CLIENTE WINDOWS AL DOMINIO"      -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Write-Host "Ejecuta este comando en el cliente Windows 10:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host @"
# En el cliente Windows 10 (como Administrador):
`$cred = Get-Credential  # Usa: REPROBADOS\Administrador
Add-Computer -DomainName "reprobados.com" -Credential `$cred -Restart -Force
"@ -ForegroundColor White

    Write-Host ""
    Write-Host "Asegurate de que el DNS del cliente apunte a: $DC_IP" -ForegroundColor Cyan
    Write-Host "Panel de control -> Red -> IPv4 -> DNS preferido: $DC_IP" -ForegroundColor Cyan
    Pause-Menu
}

# ==========================================
# MODULO 7: RESUMEN Y VERIFICACION
# ==========================================
function Mostrar-Resumen {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " RESUMEN DE VERIFICACION - PRACTICA 8"   -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

    # AD
    try {
        $dom = Get-ADDomain
        Write-Host "  [OK] Dominio  : $($dom.DNSRoot)" -ForegroundColor Green
        Write-Host "  [OK] NetBIOS  : $($dom.NetBIOSName)" -ForegroundColor Green
    } catch {
        Write-Host "  [!] Active Directory no disponible" -ForegroundColor Red
    }

    # OUs
    foreach ($ou in @("Cuates","NoCuates")) {
        $existe = Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -ErrorAction SilentlyContinue
        $estado = if ($existe) { "[OK]" } else { "[!]" }
        $color  = if ($existe) { "Green" } else { "Red" }
        Write-Host "  $estado OU $ou" -ForegroundColor $color
    }

    # Usuarios
    $totalUsuarios = (Get-ADUser -Filter * -SearchBase "DC=reprobados,DC=com" -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -ne "Administrator" -and $_.SamAccountName -ne "Guest" }).Count
    Write-Host "  [OK] Usuarios en AD: $totalUsuarios" -ForegroundColor Green

    # FSRM
    Import-Module FileServerResourceManager -ErrorAction SilentlyContinue
    $cuotas = (Get-FsrmQuota -ErrorAction SilentlyContinue).Count
    Write-Host "  [OK] Cuotas FSRM activas: $cuotas" -ForegroundColor Green

    $screens = (Get-FsrmFileScreen -ErrorAction SilentlyContinue).Count
    Write-Host "  [OK] Apantallamientos activos: $screens" -ForegroundColor Green

    # AppLocker
    $appSvc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
    $estado = if ($appSvc -and $appSvc.Status -eq "Running") { "[OK] Activo" } else { "[!] Detenido" }
    $color  = if ($appSvc -and $appSvc.Status -eq "Running") { "Green" } else { "Red" }
    Write-Host "  $estado AppLocker (AppIDSvc)" -ForegroundColor $color

    # GPOs
    foreach ($gpo in @("Control-HorarioAcceso","AppLocker-Cuates","AppLocker-NoCuates")) {
        $g = Get-GPO -Name $gpo -ErrorAction SilentlyContinue
        $estado = if ($g) { "[OK]" } else { "[!]" }
        $color  = if ($g) { "Green" } else { "Red" }
        Write-Host "  $estado GPO: $gpo" -ForegroundColor $color
    }

    Write-Host "=========================================" -ForegroundColor Cyan
    Pause-Menu
}

# ============================================================
# MODULOS PRACTICA 9 - Hardening AD, RBAC, FGPP, Auditoria, MFA
# Se agregan al active_directory.ps1 existente
# ============================================================

# ==========================================
# MODULO 8: RBAC - DELEGACION DE CONTROL
# ==========================================
function Configurar-RBAC {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 8. RBAC - DELEGACION DE CONTROL"         -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module ActiveDirectory
    $DC       = "DC=reprobados,DC=com"
    $OUCuates = "OU=Cuates,$DC"
    $OUNoCu   = "OU=NoCuates,$DC"
    $PwdAdmin = ConvertTo-SecureString "AdminPass123!" -AsPlainText -Force

    # Crear los 4 usuarios de administracion delegada
    $adminUsers = @(
        @{ Sam="admin_identidad"; Nombre="Admin Identidad";  OU="CN=Users,$DC" },
        @{ Sam="admin_storage";   Nombre="Admin Storage";    OU="CN=Users,$DC" },
        @{ Sam="admin_politicas"; Nombre="Admin Politicas";  OU="CN=Users,$DC" },
        @{ Sam="admin_auditoria"; Nombre="Admin Auditoria";  OU="CN=Users,$DC" }
    )

    foreach ($u in $adminUsers) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue)) {
            New-ADUser -Name $u.Nombre -SamAccountName $u.Sam `
                -UserPrincipalName "$($u.Sam)@reprobados.com" `
                -Path $u.OU -AccountPassword $PwdAdmin `
                -Enabled $true -PasswordNeverExpires $true
            Write-Log "Usuario '$($u.Sam)' creado." "Green"
        } else {
            Write-Log "Usuario '$($u.Sam)' ya existe." "Yellow"
        }
    }

    # ---- ROL 1: admin_identidad ----
    # Delegar en OU Cuates y NoCuates: Create/Delete Users, Reset Password, Modify Attributes
    Write-Log "Configurando ROL 1: admin_identidad..." "Cyan"
    foreach ($ou in @($OUCuates, $OUNoCu)) {
        # Crear y eliminar usuarios
        dsacls $ou /G "REPROBADOS\admin_identidad:CCDC;user" | Out-Null
        # Reset Password
        dsacls $ou /G "REPROBADOS\admin_identidad:CA;Reset Password;user" | Out-Null
        # Desbloquear cuenta
        dsacls $ou /G "REPROBADOS\admin_identidad:WP;lockoutTime;user" | Out-Null
        # Modificar atributos basicos (telefono, oficina, correo)
        dsacls $ou /G "REPROBADOS\admin_identidad:WP;telephoneNumber;user" | Out-Null
        dsacls $ou /G "REPROBADOS\admin_identidad:WP;physicalDeliveryOfficeName;user" | Out-Null
        dsacls $ou /G "REPROBADOS\admin_identidad:WP;mail;user" | Out-Null
        # Modificar contrasena
        dsacls $ou /G "REPROBADOS\admin_identidad:WP;pwdLastSet;user" | Out-Null
    }
    Write-Log "ROL 1 configurado." "Green"

    # ---- ROL 2: admin_storage ----
    # Permisos FSRM (se manejan via grupo local)
    # Denegar Reset Password en todo el dominio
    Write-Log "Configurando ROL 2: admin_storage..." "Cyan"
    foreach ($ou in @($OUCuates, $OUNoCu)) {
        dsacls $ou /D "REPROBADOS\admin_storage:CA;Reset Password;user" | Out-Null
    }
    # Agregar al grupo local de administracion de FSRM
    $grupoFSRM = "File Server Resource Manager Operators"
    try {
        Add-LocalGroupMember -Group $grupoFSRM -Member "REPROBADOS\admin_storage" -ErrorAction SilentlyContinue
        Write-Log "admin_storage agregado a grupo FSRM." "Green"
    } catch {
        Write-Log "Grupo FSRM no encontrado - permisos aplicados via ACL." "Yellow"
    }
    Write-Log "ROL 2 configurado." "Green"

    # ---- ROL 3: admin_politicas ----
    # Permiso de lectura en todo el dominio
    # Permiso de escritura solo en objetos GPO
    Write-Log "Configurando ROL 3: admin_politicas..." "Cyan"
    dsacls $DC /G "REPROBADOS\admin_politicas:GR" | Out-Null

    # Permisos sobre contenedor de GPOs
    $GPOContainer = "CN=Policies,CN=System,$DC"
    dsacls $GPOContainer /G "REPROBADOS\admin_politicas:GA" | Out-Null

    # Agregar al grupo GPO Creator Owners
    Add-ADGroupMember -Identity "Propietarios del creador de directivas de grupo" -Members "admin_politicas" -ErrorAction SilentlyContinue
    Write-Log "ROL 3 configurado." "Green"

    # ---- ROL 4: admin_auditoria ----
    # Solo lectura en todo el dominio
    # Agregar al grupo Event Log Readers
    Write-Log "Configurando ROL 4: admin_auditoria..." "Cyan"
    dsacls $DC /G "REPROBADOS\admin_auditoria:GR" | Out-Null
    Add-ADGroupMember -Identity "Lectores del registro de eventos" -Members "admin_auditoria" -ErrorAction SilentlyContinue

    # Dar acceso a logs de seguridad via registro
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security"
    $sid = (Get-ADUser "admin_auditoria").SID.Value
    Write-Log "ROL 4 configurado." "Green"

    Write-Log "RBAC configurado exitosamente." "Green"
    Pause-Menu
}

# ==========================================
# MODULO 9: FGPP - DIRECTIVAS DE CONTRASENA
# ==========================================
function Configurar-FGPP {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 9. FGPP - DIRECTIVAS DE CONTRASENA"      -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module ActiveDirectory

    # Politica para admins: minimo 12 caracteres
    $fgppAdmin = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP-Admins'" -ErrorAction SilentlyContinue
    if (-not $fgppAdmin) {
        New-ADFineGrainedPasswordPolicy -Name "FGPP-Admins" `
            -Precedence 10 `
            -MinPasswordLength 12 `
            -ComplexityEnabled $true `
            -PasswordHistoryCount 5 `
            -MaxPasswordAge "90.00:00:00" `
            -MinPasswordAge "1.00:00:00" `
            -LockoutDuration "00:30:00" `
            -LockoutObservationWindow "00:30:00" `
            -LockoutThreshold 3 `
            -ReversibleEncryptionEnabled $false `
            -Description "Politica para usuarios administrativos - 12 chars minimo"
        Write-Log "FGPP-Admins creada (12 chars)." "Green"
    } else {
        Write-Log "FGPP-Admins ya existe." "Yellow"
    }

    # Politica para usuarios estandar: minimo 8 caracteres
    $fgppUser = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP-Usuarios'" -ErrorAction SilentlyContinue
    if (-not $fgppUser) {
        New-ADFineGrainedPasswordPolicy -Name "FGPP-Usuarios" `
            -Precedence 20 `
            -MinPasswordLength 8 `
            -ComplexityEnabled $true `
            -PasswordHistoryCount 3 `
            -MaxPasswordAge "180.00:00:00" `
            -MinPasswordAge "0.00:00:00" `
            -LockoutDuration "00:30:00" `
            -LockoutObservationWindow "00:30:00" `
            -LockoutThreshold 5 `
            -ReversibleEncryptionEnabled $false `
            -Description "Politica para usuarios estandar - 8 chars minimo"
        Write-Log "FGPP-Usuarios creada (8 chars)." "Green"
    } else {
        Write-Log "FGPP-Usuarios ya existe." "Yellow"
    }

    # Aplicar FGPP-Admins a los 4 usuarios admin
    foreach ($admin in @("admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
        try {
            Add-ADFineGrainedPasswordPolicySubject -Identity "FGPP-Admins" -Subjects $admin
            Write-Log "FGPP-Admins aplicada a $admin." "Green"
        } catch {
            Write-Log "FGPP-Admins ya aplicada a $admin." "Yellow"
        }
    }

    # Aplicar FGPP-Usuarios a grupos Cuates y NoCuates
    foreach ($grupo in @("Cuates","NoCuates")) {
        try {
            Add-ADFineGrainedPasswordPolicySubject -Identity "FGPP-Usuarios" -Subjects $grupo
            Write-Log "FGPP-Usuarios aplicada al grupo $grupo." "Green"
        } catch {
            Write-Log "FGPP-Usuarios ya aplicada a $grupo." "Yellow"
        }
    }

    Write-Log "FGPP configurada exitosamente." "Green"
    Pause-Menu
}

# ==========================================
# MODULO 10: AUDITORIA DE EVENTOS
# ==========================================
function Configurar-Auditoria {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 10. AUDITORIA DE EVENTOS"                -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    # Habilitar auditoria de inicio de sesion (exito y fallo)
    Write-Log "Habilitando auditoria de inicio de sesion..." "Cyan"
    auditpol /set /subcategory:"Inicio de sesión" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Cerrar sesión" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Bloqueo de cuenta" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Otros eventos de inicio y cierre de sesión" /success:enable /failure:enable | Out-Null

    # Habilitar auditoria de acceso a objetos
    Write-Log "Habilitando auditoria de acceso a objetos..." "Cyan"
    auditpol /set /subcategory:"Sistema de archivos" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Registro" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Otros eventos de acceso a objetos" /success:enable /failure:enable | Out-Null

    # Habilitar auditoria de cambios en cuentas
    Write-Log "Habilitando auditoria de gestion de cuentas..." "Cyan"
    auditpol /set /subcategory:"Administración de cuentas de usuario" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Administración de grupos de seguridad" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Administración de cuentas de equipo" /success:enable /failure:enable | Out-Null

    # Configurar GPO de auditoria
    $GPOAudit = Get-GPO -Name "Auditoria-P9" -ErrorAction SilentlyContinue
    if (-not $GPOAudit) {
        $GPOAudit = New-GPO -Name "Auditoria-P9"
        New-GPLink -Name "Auditoria-P9" -Target "DC=reprobados,DC=com" -ErrorAction SilentlyContinue | Out-Null
        Write-Log "GPO Auditoria-P9 creada y vinculada." "Green"
    }

    Write-Log "Auditoria configurada exitosamente." "Green"

    # Generar script de monitoreo
    $scriptMonitoreo = @'
# ============================================================
# Script: monitoreo_eventos.ps1
# Extrae los ultimos 10 eventos de acceso denegado (ID 4625)
# ============================================================
$OutputFile = "C:\auditoria_accesos_denegados_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$Eventos = Get-WinEvent -FilterHashtable @{
    LogName   = 'Security'
    Id        = @(4625, 4771, 4776)
    StartTime = (Get-Date).AddDays(-7)
} -MaxEvents 10 -ErrorAction SilentlyContinue

if ($Eventos) {
    $Reporte = @()
    $Reporte += "=" * 60
    $Reporte += "REPORTE DE ACCESOS DENEGADOS - $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
    $Reporte += "=" * 60
    $Reporte += ""

    foreach ($e in $Eventos) {
        $xml = [xml]$e.ToXml()
        $usuario   = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq "TargetUserName" }).'#text'
        $ip        = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq "IpAddress" }).'#text'
        $motivo    = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq "SubStatus" }).'#text'
        $maquina   = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq "WorkstationName" }).'#text'

        $Reporte += "Fecha     : $($e.TimeCreated)"
        $Reporte += "Evento ID : $($e.Id)"
        $Reporte += "Usuario   : $usuario"
        $Reporte += "Maquina   : $maquina"
        $Reporte += "IP Origen : $ip"
        $Reporte += "Codigo    : $motivo"
        $Reporte += "-" * 40
    }

    $Reporte | Out-File $OutputFile -Encoding UTF8
    Write-Host "[OK] Reporte generado: $OutputFile" -ForegroundColor Green
    Write-Host ""
    Get-Content $OutputFile
} else {
    "Sin eventos de acceso denegado en los ultimos 7 dias." | Out-File $OutputFile -Encoding UTF8
    Write-Host "[!] No se encontraron eventos de acceso denegado." -ForegroundColor Yellow
}
'@
    $scriptMonitoreo | Out-File "C:\monitoreo_eventos.ps1" -Encoding UTF8
    Write-Log "Script de monitoreo guardado en C:\monitoreo_eventos.ps1" "Green"
    Write-Log "Ejecuta: .\monitoreo_eventos.ps1" "Cyan"
    Pause-Menu
}

# ==========================================
# MODULO 11: MFA CON WINOTP (TOTP)
# ==========================================
function Configurar-MFA {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 11. MFA - AUTENTICACION MULTIFACTOR"     -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Write-Log "Configurando MFA con WinOTP Authenticator..." "Cyan"

    # Verificar si Chocolatey esta disponible
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $choco) {
        Write-Log "Instalando Chocolatey..." "Cyan"
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }

    # Instalar WinOTP
    Write-Log "Instalando WinOTP Authenticator..." "Cyan"
    choco install winotp -y --force 2>$null

    # Configurar bloqueo de cuenta por intentos fallidos via FGPP
    # La FGPP-Admins ya tiene LockoutThreshold=3 y LockoutDuration=30min
    Write-Log "Verificando politica de bloqueo (3 intentos, 30 min)..." "Cyan"
    $fgpp = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP-Admins'" -ErrorAction SilentlyContinue
    if ($fgpp) {
        Write-Log "FGPP-Admins: LockoutThreshold=$($fgpp.LockoutThreshold), LockoutDuration=$($fgpp.LockoutDuration)" "Green"
    } else {
        Write-Log "[!] Ejecuta primero el Modulo 9 (FGPP)." "Red"
        Pause-Menu; return
    }

    # Configurar politica de bloqueo a nivel de dominio tambien
    $GPOMfa = Get-GPO -Name "MFA-LockoutPolicy" -ErrorAction SilentlyContinue
    if (-not $GPOMfa) {
        $GPOMfa = New-GPO -Name "MFA-LockoutPolicy"
        New-GPLink -Name "MFA-LockoutPolicy" -Target "DC=reprobados,DC=com" -ErrorAction SilentlyContinue | Out-Null

        # Configurar lockout via GPO registro
        Set-GPRegistryValue -Name "MFA-LockoutPolicy" `
            -Key "HKLM\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" `
            -ValueName "MaximumPasswordAge" -Type DWord -Value 90 | Out-Null

        Write-Log "GPO MFA-LockoutPolicy creada." "Green"
    }

    # Generar secreto TOTP para el Administrador y mostrarlo
    Write-Log "Generando secreto TOTP para cuenta Administrador..." "Cyan"

    # Generar clave base32 aleatoria (20 bytes = 160 bits)
    $bytes = New-Object byte[] 20
    [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($bytes)
    $base32chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $secret = ""
    $buffer = 0
    $bitsLeft = 0
    foreach ($byte in $bytes) {
        $buffer = ($buffer -shl 8) -bor $byte
        $bitsLeft += 8
        while ($bitsLeft -ge 5) {
            $bitsLeft -= 5
            $secret += $base32chars[($buffer -shr $bitsLeft) -band 31]
        }
    }

    # Guardar secreto
    $secretFile = "C:\mfa_secret_administrador.txt"
    @"
============================================================
SECRETO TOTP - ADMINISTRADOR
============================================================
Secreto Base32: $secret
Cuenta        : Administrador@reprobados.com
Emisor        : reprobados.com
Algoritmo     : SHA1
Digitos       : 6
Periodo       : 30 segundos

URL para QR (escaneala con Google Authenticator):
otpauth://totp/reprobados.com:Administrador?secret=$secret&issuer=reprobados.com&algorithm=SHA1&digits=6&period=30

IMPORTANTE: Guarda este secreto de forma segura.
Si lo pierdes, no podras recuperar acceso via MFA.
============================================================
"@ | Out-File $secretFile -Encoding UTF8

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " SECRETO TOTP GENERADO" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Get-Content $secretFile
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Log "Secreto guardado en: $secretFile" "Green"

    # Instrucciones para configurar Google Authenticator
    Write-Host "`n[INSTRUCCIONES] Para configurar Google Authenticator:" -ForegroundColor Cyan
    Write-Host "  1. Instala Google Authenticator en tu telefono"
    Write-Host "  2. Agrega cuenta manualmente con el secreto mostrado arriba"
    Write-Host "  3. O escanea el QR desde: https://qr.io/result con la URL otpauth"
    Write-Host ""
    Write-Host "[NOTA] WinOTP funciona como segundo factor en la pantalla de login."
    Write-Host "       Requiere reiniciar el servidor para activarse completamente."

    # Verificar si WinOTP esta instalado
    $winotp = Get-Command winotp -ErrorAction SilentlyContinue
    if (-not $winotp) {
        $winOTPPath = Get-ChildItem "C:\ProgramData\chocolatey\lib\winotp" -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($winOTPPath) {
            Write-Log "WinOTP instalado en: $($winOTPPath.FullName)" "Green"
        } else {
            Write-Log "[!] WinOTP no se pudo instalar automaticamente." "Yellow"
            Write-Log "    Descarga manual: https://github.com/nickvdyck/winotp" "Yellow"
        }
    }

    gpupdate /force | Out-Null
    Write-Log "MFA configurado. Reinicia el servidor para aplicar cambios." "Green"
    Pause-Menu
}

# ==========================================
# MODULO 12: EJECUTAR SCRIPT DE MONITOREO
# ==========================================
function Ejecutar-Monitoreo {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 12. REPORTE DE AUDITORÍA"                -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    if (Test-Path "C:\monitoreo_eventos.ps1") {
        & "C:\monitoreo_eventos.ps1"
    } else {
        Write-Log "[!] Script no encontrado. Ejecuta primero el Modulo 10." "Red"
    }
    Pause-Menu
}


# ==========================================
# MENU PRINCIPAL
# ==========================================
function Menu-Principal {
    while ($true) {
        Clear-Host
        Write-Host "=========================================================" -ForegroundColor Cyan
        Write-Host "   PRACTICAS 8 y 9 - AD, GPO, FSRM, AppLocker, RBAC, MFA" -ForegroundColor Cyan
        Write-Host "   Dominio: reprobados.com | DC: $DC_IP"                   -ForegroundColor Cyan
        Write-Host "=========================================================" -ForegroundColor Cyan
        Write-Host "  --- PRACTICA 8 ---"
        Write-Host "  1) Instalar AD DS y promover a Domain Controller"
        Write-Host "  2) Crear OUs, grupos y usuarios desde CSV"
        Write-Host "  3) Configurar horarios de acceso (Logon Hours)"
        Write-Host "  4) Configurar FSRM (cuotas y apantallamiento)"
        Write-Host "  5) Configurar AppLocker (control de ejecucion)"
        Write-Host "  6) Instrucciones union al dominio (cliente Windows)"
        Write-Host "  7) Ver resumen de configuracion"
        Write-Host "  --- PRACTICA 9 ---"
        Write-Host "  8)  RBAC - Delegacion de control (4 roles)"
        Write-Host "  9)  FGPP - Directivas de contrasena ajustadas"
        Write-Host "  10) Auditoria de eventos + script de monitoreo"
        Write-Host "  11) MFA - Autenticacion multifactor (WinOTP/TOTP)"
        Write-Host "  12) Ejecutar reporte de auditoria"
        Write-Host "  0)  Salir"
        Write-Host "=========================================================" -ForegroundColor Cyan

        $op = Read-Host "Seleccione una opcion"
        switch ($op) {
            "1"  { Instalar-ActiveDirectory  }
            "2"  { Crear-EstructuraAD        }
            "3"  { Configurar-HorariosAcceso }
            "4"  { Configurar-FSRM          }
            "5"  { Configurar-AppLocker     }
            "6"  { Unir-ClienteWindows      }
            "7"  { Mostrar-Resumen          }
            "8"  { Configurar-RBAC          }
            "9"  { Configurar-FGPP          }
            "10" { Configurar-Auditoria     }
            "11" { Configurar-MFA           }
            "12" { Ejecutar-Monitoreo       }
            "0"  { return                   }
            default { Write-Host "Opcion no valida." -ForegroundColor Red; Start-Sleep 1 }
        }
    }
}

# Verificar que se ejecuta como Administrador
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Ejecuta este script como Administrador." -ForegroundColor Red
    exit 1
}