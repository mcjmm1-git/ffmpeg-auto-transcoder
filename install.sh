#!/usr/bin/env bash

###############################################################################
# FFmpeg Auto Transcoder
# Instalador
###############################################################################

set -e

VERSION="1.1.0"

DEFAULT_INSTALL_DIR="/opt/ffmpeg-auto-transcoder"

###############################################################################
# VARIABLES
###############################################################################

INSTALL_DIR=""
MEDIA_DIR=""
REAL_USER=""

###############################################################################
# FUNCIONES
###############################################################################

check_root() {

    if [[ $EUID -ne 0 ]]; then
        echo
        echo "Este instalador debe ejecutarse con sudo."
        echo
        echo "Ejecute:"
        echo
        echo "sudo ./install.sh"
        echo
        exit 1
    fi

}

detect_user() {

    REAL_USER="${SUDO_USER:-$(logname)}"

}


detect_package_manager() {

    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"

    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"

    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"

    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"

    else
        echo
        echo "No se ha encontrado un gestor de paquetes compatible."
        exit 1
    fi

}

check_nvidia() {

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo
        echo "ERROR: No se ha detectado una GPU NVIDIA."
        echo
        echo "FFmpeg Auto Transcoder requiere NVIDIA NVENC."
        echo
        exit 1
    fi

}

check_dependencies() {

    local dependencies=(
        rsync
    )

    for program in "${dependencies[@]}"; do

        if ! command -v "$program" >/dev/null 2>&1; then
            echo
            echo "ERROR: $program no está instalado."
            echo
            exit 1
        fi

    done

}

install_package() {

    local PACKAGE="$1"

    case "$PKG_MANAGER" in

        apt)
            apt install -y "$PACKAGE"
            ;;

        dnf)
            dnf install -y "$PACKAGE"
            ;;

        pacman)
            pacman -Sy --noconfirm "$PACKAGE"
            ;;

        zypper)
            zypper install -y "$PACKAGE"
            ;;

    esac

    if ! command -v "$PACKAGE" >/dev/null 2>&1; then
        echo
        echo "ERROR: No se ha podido instalar '$PACKAGE'."
        exit 1
    fi

}

install_dependencies() {

    echo
    echo "[1/7] Instalando dependencias..."
    echo

    local REQUIRED=(
        rsync
        ffmpeg
        jq
        curl
        bc
        ttyd
    )

    for PACKAGE in "${REQUIRED[@]}"; do

        if command -v "$PACKAGE" >/dev/null 2>&1; then
            echo "✔ $PACKAGE"
            continue
        fi

        echo "Instalando $PACKAGE..."

        install_package "$PACKAGE"

    done

}

ask_install_directory() {

    while true; do

        echo
        read -rp "Directorio de instalación [/opt/ffmpeg-auto-transcoder]: " INSTALL_DIR

        if [[ -z "$INSTALL_DIR" ]]; then
            INSTALL_DIR="/opt/ffmpeg-auto-transcoder"
        fi

        break

    done

}

ask_media_directory() {

    while true; do

        echo
        echo "Ejemplo: /mnt/dd2"
        echo

        read -rp "Ruta de la biblioteca multimedia: " MEDIA_DIR

        if [[ -z "$MEDIA_DIR" ]]; then
            echo
            echo "Debe indicar una ruta."
            continue
        fi

        if [[ ! -d "$MEDIA_DIR" ]]; then

            echo
            echo "La carpeta no existe."
            echo

            read -rp "¿Desea crearla? [S/n]: " RESP

            if [[ "$RESP" =~ ^[Nn]$ ]]; then
                continue
            fi

            mkdir -p "$MEDIA_DIR" || {
                echo
                echo "No se ha podido crear la carpeta."
                continue
            }

        else

            echo
            echo "La biblioteca multimedia ya existe:"
            echo "  $MEDIA_DIR"
            echo

            read -rp "¿Desea utilizar esta biblioteca? [S/n]: " RESP

            if [[ "$RESP" =~ ^[Nn]$ ]]; then
                continue
            fi

        fi

        echo
        echo "Creando estructura de directorios..."
        echo

mkdir -p \
    "$MEDIA_DIR/incoming" \
    "$MEDIA_DIR/processing" \
    "$MEDIA_DIR/library" \
    "$MEDIA_DIR/completed" \
    "$MEDIA_DIR/failed" \
    "$MEDIA_DIR/logs" \
    "$MEDIA_DIR/temp"

break

done

}

show_summary() {

    clear

    echo "==============================================="
    echo " FFmpeg Auto Transcoder Installer"
    echo "==============================================="
    echo
    echo "Versión : $VERSION"
    echo
    echo "Usuario : $REAL_USER"
    echo
    echo "Instalación : $INSTALL_DIR"
    echo
    echo "Biblioteca : $MEDIA_DIR"
    echo

}

check_ffmpeg_nvenc() {

    if ! ffmpeg -hide_banner -encoders | grep -q "hevc_nvenc"; then
        echo
        echo "ERROR: La instalación de FFmpeg no incluye el codificador HEVC NVENC."
        echo "Instale una versión de FFmpeg con soporte para NVIDIA NVENC."
        echo
        exit 1
    fi

}

copy_project() {

    echo
    echo "[2/7] Copiando archivos..."
    echo

    if [[ -d "$INSTALL_DIR" ]]; then

        echo
        echo "El directorio ya existe."

        read -rp "¿Sobrescribir? [s/N]: " RESP

        if [[ "$RESP" =~ ^[Nn]$ || -z "$RESP" ]]; then
            echo
            echo "Instalación cancelada."
            exit 0
        fi

        rm -rf "$INSTALL_DIR"

    fi

    if ! command -v rsync >/dev/null 2>&1; then
        echo
        echo "ERROR: rsync no está instalado."
        echo
        echo "Instálelo e inténtelo de nuevo."
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"

    rsync -a \
    --exclude=".git" \
    --exclude=".github" \
    --exclude=".gitignore" \
    --exclude="*.bak" \
    --exclude="install.sh" \
    ./ "$INSTALL_DIR"

chmod +x \
    "$INSTALL_DIR/procesar.sh" \
    "$INSTALL_DIR/monitor.sh" \
    "$INSTALL_DIR/monitor-web.sh" \
    "$INSTALL_DIR/lib/tmdb.sh" \
    "$INSTALL_DIR/lib/omdb.sh"

chown -R "$REAL_USER":"$REAL_USER" "$MEDIA_DIR"
}

generate_config() {

    echo
    echo "[3/7] Generando configuración..."
    echo

    mkdir -p /etc/ffmpeg-auto-transcoder

    sed \
        -e "s|__MEDIA_DIR__|$MEDIA_DIR|g" \
        "$INSTALL_DIR/templates/config.sh.template" \
        > "/etc/ffmpeg-auto-transcoder/config.sh"

    rm -f "$INSTALL_DIR/templates/config.sh.template"

}


save_install_info() {

    echo
    echo "[4/7] Guardando información de la instalación..."
    echo

    mkdir -p /etc/ffmpeg-auto-transcoder

    cat > /etc/ffmpeg-auto-transcoder/install.conf <<EOF
INSTALL_DIR="$INSTALL_DIR"
MEDIA_DIR="$MEDIA_DIR"
REAL_USER="$REAL_USER"
VERSION="$VERSION"
EOF

}

generate_services() {

    echo
    echo "[5/7] Generando servicios..."
    echo

    sed \
        -e "s|__USER__|$REAL_USER|g" \
        -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
        "$INSTALL_DIR/templates/procesar.service.template" \
        > /etc/systemd/system/procesar.service

    sed \
        -e "s|__USER__|$REAL_USER|g" \
        -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
        "$INSTALL_DIR/templates/ffmpeg-monitor.service.template" \
        > /etc/systemd/system/ffmpeg-monitor.service

}

install_services() {

    echo
    echo "[6/7] Instalando servicios..."
    echo

    systemctl daemon-reload

    systemctl enable procesar.service
    systemctl enable ffmpeg-monitor.service

}

start_services() {

    echo
    echo "[7/7] Iniciando servicios..."
    echo

    systemctl restart procesar.service
    systemctl restart ffmpeg-monitor.service

}

finish() {

echo
echo "==============================================="
echo " Instalación completada correctamente"
echo "==============================================="
echo

echo "Directorio instalado:"
echo "  $INSTALL_DIR"
echo

echo "Biblioteca multimedia:"
echo "  $MEDIA_DIR"
echo

echo "Estado del servicio:"
echo
echo "  sudo systemctl status procesar.service"
echo

echo "Monitor web:"
echo
echo "  http://IP_DEL_SERVIDOR:9001"
echo

echo "⚠ IMPORTANTE"
echo
echo "Edite el siguiente archivo:"
echo
echo "  /etc/ffmpeg-auto-transcoder/config.sh"
echo
echo "e introduzca sus claves API:"
echo
echo "  • TMDB_API_KEY"
echo "  • OMDB_API_KEY"
echo
echo "Sin estas claves el programa no podrá"
echo "identificar ni organizar correctamente"
echo "las películas."
echo

echo "Disfruta 😊"
echo

}

###############################################################################
# MAIN
###############################################################################

check_root

detect_user

detect_package_manager

check_nvidia

check_dependencies

ask_install_directory

ask_media_directory

show_summary

read -rp "¿Continuar con la instalación? [S/n]: " RESP

if [[ "$RESP" =~ ^[Nn]$ ]]; then
    echo
    echo "Instalación cancelada."
    exit 0
fi

install_dependencies

check_ffmpeg_nvenc

copy_project

generate_config

save_install_info

generate_services

install_services

start_services

finish
