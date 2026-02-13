#!/bin/bash
echo "--------------------------------------------------"
echo "   Reporte de estado del sistema    "
echo "--------------------------------------------------"
echo ""
echo "Fecha: $(date)"
echo ""
echo "1. NOMBRE DEL EQUIPO: "
hostname
echo ""
echo "2. DIRECCIONES IP: "
ip a | grep inet | grep -v 127.0.0.1 | awk '{print $2}'
echo ""
echo "3. ESPACIO EN DISCO: "
df -h | grep -E '^/dev/'
echo ""
echo "--------------------------------------------------"