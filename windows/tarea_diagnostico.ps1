Clear-Host
Write-Host "----------------------------------" -ForegroundColor Magenta
Write-Host "   Reporte del estado del sistema " -ForegroundColor Cyan
Write-Host "----------------------------------" -ForegroundColor Magenta
Write-Host ""
Write-Host "Fecha: $(Get-Date)"
Write-Host ""

Write-Host "A) Nombre del equipo: " -ForegroundColor DarkCyan
Hostname
Write-Host ""

Write-Host "B) Direcciones IP (Red Interna):" -ForegroundColor DarkCyan
Get-NetIPAddress | Where-Object {$_.AddressFamily -eq "IPv4" -and $_.InterfaceAlias -ne "Loopback Pseudo-Interface 1"} | Select-Object IPAddress, InterfaceAlias
Write-Host ""

Write-Host "C) Espacio en Disco: " -ForegroundColor DarkCyan
Get-PSDrive C | Select-Object @{Name="Usado (GB)";Expression={"{0:N2}" -f ($_.Used/1GB)}}, @{Name="Libre (GB)";Expression={"{0:N2}" -f ($_.Free/1GB)}}, @{Name="Total (GB)";Expression={"{0:N2}" -f (($_.Used + $_.Free)/1GB)}} | Format-List
Write-Host ""
Write-Host "----------------------------------"