#!/usr/bin/env bash

###############################################################################
# FFmpeg Auto Transcoder
# Desinstalador
###############################################################################

set -e

CONFIG_FILE="/etc/ffmpeg-auto-transcoder/install.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo
    echo "No se ha encontrado información de la instalación."
    echo "No es posible continuar con la desinstalación."
    echo
    exit 1
fi

source "$CONFIG_FILE"

###############################################################################
# VARIABLES
###############################################################################

SERVICES=(
    procesar.service
    ffmpeg-monitor.service
)

PROGRAM_REMOVED=false
CONFIG_REMOVED=false
MEDIA_REMOVED=false

###############################################################################
# FUNCIONES
###############################################################################

check_root() {

    if [[ $EUID -ne 0 ]]; then
        echo
        echo "Este desinstalador debe ejecutarse con sudo."
        echo
        echo "sudo ./uninstall.sh"
        echo
        exit 1
    fi

}

stop_services() {

    echo
    echo "[1/7] Deteniendo servicios..."
    echo

    for SERVICE in "${SERVICES[@]}"; do

        if systemctl is-active --quiet "$SERVICE"; then
            systemctl stop "$SERVICE"
            echo "✔ $SERVICE detenido"
        else
            echo "- $SERVICE ya estaba detenido"
        fi

    done

}

disable_services() {

    echo
    echo "[2/7] Deshabilitando servicios..."
    echo

    for SERVICE in "${SERVICES[@]}"; do

        if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
            systemctl disable "$SERVICE" >/dev/null
            echo "✔ $SERVICE deshabilitado"
        else
            echo "- $SERVICE ya estaba deshabilitado"
        fi

    done

}

remove_service_files() {

    echo
    echo "[3/7] Eliminando servicios..."
    echo

    for SERVICE in "${SERVICES[@]}"; do

        SERVICE_FILE="/etc/systemd/system/$SERVICE"

        if [[ -f "$SERVICE_FILE" ]]; then
            rm -f "$SERVICE_FILE"
            echo "✔ $SERVICE_FILE"
        else
            echo "- $SERVICE_FILE no existe"
        fi

    done

}

reload_systemd() {

    echo
    echo "[4/7] Recargando systemd..."
    echo

    systemctl daemon-reload

    echo "✔ daemon-reload"

}

remove_program() {

    echo
    echo "[5/7] Eliminando programa..."
    echo

    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        echo "✔ $INSTALL_DIR eliminado"
        PROGRAM_REMOVED=true
    else
        echo "- $INSTALL_DIR no existe"
    fi

}

remove_configuration() {

    echo
    echo "[6/7] Eliminando configuración..."
    echo

    read -rp "¿Desea eliminar también la configuración? [s/N]: " RESP

    if [[ "$RESP" =~ ^[Ss]$ ]]; then

        if [[ -d "/etc/ffmpeg-auto-transcoder" ]]; then
            rm -rf /etc/ffmpeg-auto-transcoder
            echo "✔ Configuración eliminada"
            CONFIG_REMOVED=true
        else
            echo "- No existe configuración"
        fi

    else

        echo "✔ Configuración conservada"

    fi

}

remove_media_directory() {

    echo
    echo "[7/7] Eliminando biblioteca multimedia..."
    echo

    read -rp "¿Desea eliminar también la biblioteca multimedia? [s/N]: " RESP

    if [[ "$RESP" =~ ^[Ss]$ ]]; then

        if [[ -d "$MEDIA_DIR" ]]; then
            rm -rf "$MEDIA_DIR"
            echo "✔ Biblioteca multimedia eliminada"
            MEDIA_REMOVED=true
        else
            echo "- La biblioteca multimedia no existe"
        fi

    else

        echo "✔ Biblioteca multimedia conservada"

    fi

}

finish() {

    echo
    echo "==============================================="
    echo " Desinstalación completada correctamente"
    echo "==============================================="
    echo

    if $PROGRAM_REMOVED; then
        echo "✔ Programa eliminado"
    else
        echo "• Programa conservado"
    fi

    if $CONFIG_REMOVED; then
        echo "✔ Configuración eliminada"
    else
        echo "✔ Configuración conservada"
    fi

    if $MEDIA_REMOVED; then
        echo "✔ Biblioteca multimedia eliminada"
    else
        echo "✔ Biblioteca multimedia conservada"
    fi

    echo "  $MEDIA_DIR"

}

###############################################################################
# MAIN
###############################################################################

check_root
stop_services
disable_services
remove_service_files
reload_systemd
remove_program
remove_configuration
finish
