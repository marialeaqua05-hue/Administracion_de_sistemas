$BASE_DIR = "C:\srv\ftp_global"
$ANON_DIR = "C:\srv\ftp_anon"
$FTP_SITE  = "FTP_Global"
$FTP_PORT  = 21

function Set-FolderPermissions {
    param(
        [string]$Path,
        [array]$Rules
    )

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)

    $knownSIDs = @{
        "Administrators"  = "S-1-5-32-544"
        "Users"           = "S-1-5-32-545"
        "Everyone"        = "S-1-1-0"
        "SYSTEM"          = "S-1-5-18"
        "CREATOR OWNER"   = "S-1-3-0"
        "IUSR"            = "S-1-5-17"
        "NETWORK SERVICE" = "S-1-5-20"
        "LOCAL SERVICE"   = "S-1-5-19"
    }

    foreach ($rule in $Rules) {
        $identity = $rule.Identity

        try {
            if ($knownSIDs.ContainsKey($identity)) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($knownSIDs[$identity])
                $resolvedIdentity = $sid.Translate([System.Security.Principal.NTAccount])
            } else {
                $resolvedIdentity = New-Object System.Security.Principal.NTAccount("$env:COMPUTERNAME\$identity")
                $resolvedIdentity.Translate([System.Security.Principal.SecurityIdentifier]) | Out-Null
            }
        } catch {
            Write-Host "    [ERROR] No se pudo resolver '$identity': $_" -ForegroundColor Red
            continue
        }

        $rights      = [System.Security.AccessControl.FileSystemRights]$rule.Rights
        $inheritance = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
        $propagation = [System.Security.AccessControl.PropagationFlags]"None"
        $type        = [System.Security.AccessControl.AccessControlType]$rule.Type

        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $resolvedIdentity, $rights, $inheritance, $propagation, $type
        )
        $acl.AddAccessRule($ace)
        Write-Host "    [OK] Regla agregada para: $identity" -ForegroundColor Green
    }

    Set-Acl -Path $Path -AclObject $acl
    Write-Host "    [OK] Permisos aplicados en: $Path" -ForegroundColor Green
}

# =========================================================================
# FUNCION AUXILIAR: Configurar reglas de autorizacion FTP via XML
# Evita el error de file lock de Clear-WebConfiguration
# =========================================================================
function Set-FtpAuthRules {
    param(
        [string]$SiteName,
        [array]$Rules,
        [string]$Location = ""
    )

    $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"

    Stop-Service -Name "W3SVC"  -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    [xml]$config = Get-Content $configPath

    if ($Location -eq "") {
        $locationAttr = $SiteName
    } else {
        $locationAttr = "$SiteName/$Location"
    }

    $locationNode = $config.configuration.SelectSingleNode("location[@path='$locationAttr']")

    if (-not $locationNode) {
        $locationNode = $config.CreateElement("location")
        $locationNode.SetAttribute("path", $locationAttr)
        $locationNode.SetAttribute("overrideMode", "Allow")
        $config.configuration.AppendChild($locationNode) | Out-Null
    }

    $ftpNode = $locationNode.SelectSingleNode("system.ftpServer")
    if (-not $ftpNode) {
        $ftpNode = $config.CreateElement("system.ftpServer")
        $locationNode.AppendChild($ftpNode) | Out-Null
    }

    $secNode = $ftpNode.SelectSingleNode("security")
    if (-not $secNode) {
        $secNode = $config.CreateElement("security")
        $ftpNode.AppendChild($secNode) | Out-Null
    }

    $authNode = $secNode.SelectSingleNode("authorization")
    if (-not $authNode) {
        $authNode = $config.CreateElement("authorization")
        $secNode.AppendChild($authNode) | Out-Null
    }

    $authNode.RemoveAll()

    foreach ($rule in $Rules) {
        $addNode = $config.CreateElement("add")
        $addNode.SetAttribute("accessType", "Allow")
        $addNode.SetAttribute("users",       $rule.users)
        $addNode.SetAttribute("roles",       $rule.roles)
        $addNode.SetAttribute("permissions", $rule.permissions)
        $authNode.AppendChild($addNode) | Out-Null
    }

    $config.Save($configPath)
    Write-Host "    [OK] Reglas de autorizacion guardadas para: $locationAttr" -ForegroundColor Green

    Start-Service -Name "W3SVC"  -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# =========================================================================
# FUNCION AUXILIAR: Configurar aislamiento de usuarios via XML
# Set-ItemProperty no funciona correctamente para userIsolation.mode
# =========================================================================
function Set-FtpUserIsolation {
    param([string]$SiteName, [string]$Mode)

    $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"

    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "W3SVC"  -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    [xml]$config = Get-Content $configPath
    $site = $config.configuration.'system.applicationHost'.sites.site |
            Where-Object { $_.name -eq $SiteName }

    # Verificar que ftpServer existe
    $ftpNode = $site.ftpServer
    if (-not $ftpNode) {
        $ftpNode = $config.CreateElement("ftpServer")
        $site.AppendChild($ftpNode) | Out-Null
    }

    # Verificar que userIsolation existe, si no crearlo
    $isolationNode = $ftpNode.SelectSingleNode("userIsolation")
    if (-not $isolationNode) {
        $isolationNode = $config.CreateElement("userIsolation")
        $ftpNode.AppendChild($isolationNode) | Out-Null
    }

    $isolationNode.SetAttribute("mode", $Mode)
    $config.Save($configPath)
    Write-Host "    [OK] Modo de aislamiento configurado: $Mode" -ForegroundColor Green

    Start-Service -Name "W3SVC"  -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# =========================================================================
# FUNCION 1: INSTALAR Y CONFIGURAR IIS + FTP
# =========================================================================
function Instalar-FTP {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 1. INSTALANDO Y CONFIGURANDO IIS + FTP"  -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Write-Host "`n[*] Verificando e instalando caracteristicas de IIS y FTP..." -ForegroundColor Yellow
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Mgmt-Console")
    foreach ($feature in $features) {
        $state = (Get-WindowsFeature -Name $feature).InstallState
        if ($state -ne "Installed") {
            Write-Host "    Instalando: $feature"
            Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null
            Write-Host "    [OK] $feature instalado." -ForegroundColor Green
        } else {
            Write-Host "    [--] $feature ya estaba instalado." -ForegroundColor DarkGray
        }
    }

    Import-Module WebAdministration -ErrorAction Stop

    Write-Host "`n[*] Creando grupos locales..." -ForegroundColor Yellow
    foreach ($grupo in @("reprobados", "recursadores", "ftp_auth")) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP: $grupo" | Out-Null
            Write-Host "    [OK] Grupo '$grupo' creado." -ForegroundColor Green
        } else {
            Write-Host "    [--] Grupo '$grupo' ya existe." -ForegroundColor DarkGray
        }
    }

    Write-Host "`n[*] Creando estructura de directorios base..." -ForegroundColor Yellow
    $dirs = @(
        "$BASE_DIR\general",
        "$BASE_DIR\reprobados",
        "$BASE_DIR\recursadores",
        "$BASE_DIR\personal",
        "$ANON_DIR\LocalUser",
        "$ANON_DIR\LocalUser\Public"   # Carpeta raiz del usuario anonimo
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Host "    [OK] Creado: $dir" -ForegroundColor Green
        } else {
            Write-Host "    [--] Ya existe: $dir" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n[*] Configurando permisos NTFS..." -ForegroundColor Yellow
    Set-FolderPermissions -Path "$BASE_DIR\general" -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl";    Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl";    Type = "Allow" },
        @{ Identity = "ftp_auth";       Rights = "Modify";         Type = "Allow" },
        @{ Identity = "IUSR";           Rights = "ReadAndExecute"; Type = "Allow" }
    )
    Set-FolderPermissions -Path "$BASE_DIR\reprobados" -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "reprobados";     Rights = "Modify";      Type = "Allow" }
    )
    Set-FolderPermissions -Path "$BASE_DIR\recursadores" -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "recursadores";   Rights = "Modify";      Type = "Allow" }
    )

    # LocalUser: solo SYSTEM y Admins, IUSR no puede listar usuarios
    Set-FolderPermissions -Path "$ANON_DIR\LocalUser" -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl"; Type = "Allow" }
    )

    # Public: IUSR solo lectura (raiz del anonimo)
    Set-FolderPermissions -Path "$ANON_DIR\LocalUser\Public" -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl";    Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl";    Type = "Allow" },
        @{ Identity = "IUSR";           Rights = "ReadAndExecute"; Type = "Allow" }
    )

    Write-Host "`n[*] Configurando junction para anonimo..." -ForegroundColor Yellow
    $anonGeneral = "$ANON_DIR\LocalUser\Public\general"
    if (Test-Path $anonGeneral) {
        $item = Get-Item $anonGeneral -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -match "ReparsePoint")) {
            Write-Host "    [--] Junction anonimo ya existe." -ForegroundColor DarkGray
        } else {
            Remove-Item $anonGeneral -Force -Recurse -ErrorAction SilentlyContinue
            cmd /c "mklink /J `"$anonGeneral`" `"$BASE_DIR\general`"" | Out-Null
            Write-Host "    [OK] Junction anonimo creado." -ForegroundColor Green
        }
    } else {
        cmd /c "mklink /J `"$anonGeneral`" `"$BASE_DIR\general`"" | Out-Null
        Write-Host "    [OK] Junction anonimo creado." -ForegroundColor Green
    }

    Write-Host "`n[*] Configurando sitio FTP en IIS..." -ForegroundColor Yellow

    Stop-Service -Name "W3SVC"  -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Import-Module WebAdministration -Force

    if (Get-WebSite -Name $FTP_SITE -ErrorAction SilentlyContinue) {
        Remove-WebSite -Name $FTP_SITE
        Write-Host "    [--] Sitio anterior eliminado para reconfigurar." -ForegroundColor DarkGray
    }

    Start-Service -Name "W3SVC"  -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    New-WebFtpSite -Name $FTP_SITE -Port $FTP_PORT -PhysicalPath $ANON_DIR | Out-Null
    Write-Host "    [OK] Sitio FTP '$FTP_SITE' creado en puerto $FTP_PORT." -ForegroundColor Green

    # Deshabilitar SSL obligatorio
    Set-ItemProperty "IIS:\Sites\$FTP_SITE" `
        -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$FTP_SITE" `
        -Name ftpServer.security.ssl.dataChannelPolicy -Value 0
    Write-Host "    [OK] SSL desactivado (modo simple)." -ForegroundColor Green

    Set-ItemProperty "IIS:\Sites\$FTP_SITE" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled `
        -Value $true
    Set-ItemProperty "IIS:\Sites\$FTP_SITE" `
        -Name ftpServer.security.authentication.anonymousAuthentication.userName `
        -Value "IUSR"
    Set-ItemProperty "IIS:\Sites\$FTP_SITE" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled `
        -Value $true

    # Configurar aislamiento via XML (IsolateAllDirectories)
    # Anonimo -> LocalUser\Public | Autenticados -> LocalUser\username
    Write-Host "`n[*] Configurando aislamiento de usuarios..." -ForegroundColor Yellow
    Set-FtpUserIsolation -SiteName $FTP_SITE -Mode "IsolateAllDirectories"

    # Reglas de autorizacion globales
    Write-Host "`n[*] Configurando reglas de autorizacion FTP..." -ForegroundColor Yellow
    Set-FtpAuthRules -SiteName $FTP_SITE -Rules @(
        @{ users = "";  roles = ""; permissions = "Read"       },
        @{ users = "*"; roles = ""; permissions = "Read,Write" }
    )

    Write-Host "`n[*] Configurando Firewall para FTP (puerto 21)..." -ForegroundColor Yellow
    $ruleName = "FTP_Server_Puerto21"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction   Inbound `
            -Protocol    TCP `
            -LocalPort   21 `
            -Action      Allow | Out-Null
        Write-Host "    [OK] Regla de firewall creada." -ForegroundColor Green
    } else {
        Write-Host "    [--] Regla de firewall ya existe." -ForegroundColor DarkGray
    }

    Write-Host "`n[*] Iniciando servicio FTPSVC..." -ForegroundColor Yellow
    Set-Service   -Name "FTPSVC" -StartupType Automatic
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Write-Host "    [OK] Servicio FTP activo." -ForegroundColor Green

    Write-Host "`n[OK] IIS + FTP instalado y configurado correctamente.`n" -ForegroundColor Green
    Read-Host "Presiona Enter para continuar"
}

# =========================================================================
# FUNCION 2: CREAR USUARIOS
# =========================================================================
function Crear-Usuarios {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 2. CREACION DE USUARIOS FTP"            -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module WebAdministration -ErrorAction Stop

    $numUsuarios = Read-Host "`nCuantos usuarios deseas crear?"
    if ($numUsuarios -notmatch '^\d+$') {
        Write-Host "Por favor ingresa un numero valido." -ForegroundColor Red
        Start-Sleep 2
        return
    }

    for ($i = 1; $i -le [int]$numUsuarios; $i++) {
        Write-Host "`n--- Usuario $i de $numUsuarios ---" -ForegroundColor Yellow

        $username = Read-Host "Nombre de usuario"
        $password = Read-Host "Contrasena" -AsSecureString

        do {
            $usergroup = Read-Host "Grupo (reprobados / recursadores)"
            if ($usergroup -notin @("reprobados","recursadores")) {
                Write-Host "    Grupo invalido. Escribe 'reprobados' o 'recursadores'." -ForegroundColor Red
            }
        } while ($usergroup -notin @("reprobados","recursadores"))

        if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
            Write-Host "    [!] El usuario '$username' ya existe, se omite creacion." -ForegroundColor DarkYellow
        } else {
            New-LocalUser -Name $username -Password $password `
                -FullName $username -Description "Usuario FTP" | Out-Null
            Write-Host "    [OK] Usuario '$username' creado." -ForegroundColor Green
        }

        foreach ($grp in @($usergroup, "ftp_auth")) {
            try {
                Add-LocalGroupMember -Group $grp -Member $username -ErrorAction Stop | Out-Null
                Write-Host "    [OK] '$username' agregado al grupo '$grp'." -ForegroundColor Green
            } catch {
                Write-Host "    [--] '$username' ya estaba en '$grp'." -ForegroundColor DarkGray
            }
        }

        $userRoot = "$ANON_DIR\LocalUser\$username"
        if (-not (Test-Path $userRoot)) {
            New-Item -ItemType Directory -Path $userRoot -Force | Out-Null
        }

        foreach ($sub in @("general", $usergroup, $username)) {
            $subPath = "$userRoot\$sub"
            if (-not (Test-Path $subPath)) {
                New-Item -ItemType Directory -Path $subPath -Force | Out-Null
            }
        }

        $personalDir = "$BASE_DIR\personal\$username"
        if (-not (Test-Path $personalDir)) {
            New-Item -ItemType Directory -Path $personalDir -Force | Out-Null
        }
        Set-FolderPermissions -Path $personalDir -Rules @(
            @{ Identity = "SYSTEM";         Rights = "FullControl"; Type = "Allow" },
            @{ Identity = "Administrators"; Rights = "FullControl"; Type = "Allow" },
            @{ Identity = $username;        Rights = "Modify";      Type = "Allow" }
        )

        $junctions = @{
            "$userRoot\general"    = "$BASE_DIR\general"
            "$userRoot\$usergroup" = "$BASE_DIR\$usergroup"
            "$userRoot\$username"  = "$BASE_DIR\personal\$username"
        }
        foreach ($link in $junctions.GetEnumerator()) {
            $linkPath   = $link.Key
            $targetPath = $link.Value
            if (Test-Path $linkPath) {
                $item = Get-Item $linkPath -ErrorAction SilentlyContinue
                if ($item -and ($item.Attributes -match "ReparsePoint")) {
                    Write-Host "    [--] Junction ya existe: $linkPath" -ForegroundColor DarkGray
                    continue
                }
                Remove-Item $linkPath -Force -Recurse
            }
            cmd /c "mklink /J `"$linkPath`" `"$targetPath`"" | Out-Null
            Write-Host "    [OK] Junction: $linkPath -> $targetPath" -ForegroundColor Green
        }

        # Raiz del usuario: solo lectura para el usuario (no puede escribir en la raiz)
        Set-FolderPermissions -Path $userRoot -Rules @(
            @{ Identity = "SYSTEM";         Rights = "FullControl";    Type = "Allow" },
            @{ Identity = "Administrators"; Rights = "FullControl";    Type = "Allow" },
            @{ Identity = $username;        Rights = "ReadAndExecute"; Type = "Allow" }
        )

        foreach ($loc in @("general", $usergroup, $username)) {
            Set-FtpAuthRules -SiteName $FTP_SITE -Location "$username/$loc" -Rules @(
                @{ users = $username; roles = ""; permissions = "Read,Write" }
            )
        }

        Write-Host "    [OK] Usuario '$username' configurado exitosamente." -ForegroundColor Green
    }

    Read-Host "`nPresiona Enter para continuar"
}

# =========================================================================
# FUNCION 3: CAMBIO DE GRUPO
# =========================================================================
function Cambiar-Grupo {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host " 3. CAMBIAR GRUPO DE USUARIO"             -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    Import-Module WebAdministration -ErrorAction Stop

    $username = Read-Host "`nNombre del usuario"

    if (-not (Get-LocalUser -Name $username -ErrorAction SilentlyContinue)) {
        Write-Host "El usuario '$username' no existe." -ForegroundColor Red
        Start-Sleep 2
        return
    }

    $oldGroup = $null
    foreach ($g in @("reprobados","recursadores")) {
        $members = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match "\\$username$" -or $_.Name -eq $username }
        if ($members) { $oldGroup = $g; break }
    }

    if (-not $oldGroup) {
        Write-Host "El usuario '$username' no pertenece a reprobados ni recursadores." -ForegroundColor Red
        Start-Sleep 2
        return
    }

    Write-Host "`nEl usuario '$username' esta actualmente en: $oldGroup" -ForegroundColor Yellow

    $newGroup = $null
    do {
        $newGroup = Read-Host "Nuevo grupo (reprobados / recursadores)"
        if ($newGroup -notin @("reprobados","recursadores")) {
            Write-Host "    Grupo invalido." -ForegroundColor Red
            $newGroup = $null
        } elseif ($newGroup -eq $oldGroup) {
            Write-Host "    Ya pertenece a ese grupo." -ForegroundColor Red
            $newGroup = $null
        }
    } while (-not $newGroup)

    $userRoot    = "$ANON_DIR\LocalUser\$username"
    $oldJunction = "$userRoot\$oldGroup"

    if (Test-Path $oldJunction) {
        cmd /c "rmdir `"$oldJunction`"" | Out-Null
        Write-Host "    [OK] Junction del grupo '$oldGroup' eliminado." -ForegroundColor Green
    }

    Remove-LocalGroupMember -Group $oldGroup -Member $username -ErrorAction SilentlyContinue
    Add-LocalGroupMember    -Group $newGroup -Member $username -ErrorAction SilentlyContinue
    Write-Host "    [OK] Membresia: $oldGroup -> $newGroup" -ForegroundColor Green

    Set-FolderPermissions -Path "$BASE_DIR\personal\$username" -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl"; Type = "Allow" },
        @{ Identity = $username;        Rights = "Modify";      Type = "Allow" }
    )

    $newJunction = "$userRoot\$newGroup"
    if (Test-Path $newJunction) {
        $item = Get-Item $newJunction -ErrorAction SilentlyContinue
        if (-not ($item.Attributes -match "ReparsePoint")) {
            Remove-Item $newJunction -Force -Recurse
        }
    }
    if (-not (Test-Path $newJunction)) {
        cmd /c "mklink /J `"$newJunction`" `"$BASE_DIR\$newGroup`"" | Out-Null
        Write-Host "    [OK] Junction nuevo: $newJunction -> $BASE_DIR\$newGroup" -ForegroundColor Green
    } else {
        Write-Host "    [--] Junction nuevo ya existia." -ForegroundColor DarkGray
    }

    Set-FtpAuthRules -SiteName $FTP_SITE -Location "$username/$oldGroup" -Rules @()
    Set-FtpAuthRules -SiteName $FTP_SITE -Location "$username/$newGroup" -Rules @(
        @{ users = $username; roles = ""; permissions = "Read,Write" }
    )

    Write-Host "`n[OK] Usuario '$username' transferido exitosamente a '$newGroup'." -ForegroundColor Green
    Read-Host "Presiona Enter para continuar"
}

# =========================================================================
# MENU PRINCIPAL
# =========================================================================
function Menu-FTP {
    while ($true) {
        Clear-Host
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host "  PANEL DE GESTION FTP (IIS) WINDOWS"    -ForegroundColor Cyan
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host " [ 1 ] Instalar y configurar Servidor FTP"
        Write-Host " [ 2 ] Crear usuarios"
        Write-Host " [ 3 ] Cambiar usuario de grupo"
        Write-Host " [ 0 ] Regresar al Panel Central"
        Write-Host "=========================================" -ForegroundColor Cyan

        $opcion = Read-Host "Selecciona una opcion"

        switch ($opcion) {
            "1" { Instalar-FTP   }
            "2" { Crear-Usuarios }
            "3" { Cambiar-Grupo  }
            "0" { return         }
            default {
                Write-Host "Opcion no valida." -ForegroundColor Red
                Start-Sleep 1
            }
        }
    }
}

# Solo ejecutar menu si el script se invoca directamente
# Si es dot-sourced desde main_powershell.ps1 no hace nada
if ($MyInvocation.InvocationName -ne '.') {
    Menu-FTP
}