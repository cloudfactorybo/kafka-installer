#!/bin/bash
# ============================================================
# get-kafka-installer.sh — Descarga la última versión del
# instalador de Kafka Seguro (TLS + SASL) desde GitHub.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/cloudfactorybo/kafka-installer/main/get-kafka-installer.sh | bash
#   curl -fsSL .../get-kafka-installer.sh | bash -s -- --run      # descarga y ejecuta
#
# Variables opcionales:
#   KAFKA_INSTALLER_REPO=usuario/repo   Repositorio de GitHub
#   KAFKA_INSTALLER_REF=v1.2.0          Versión (tag) concreta; por defecto la última release
#   KAFKA_INSTALLER_URL=https://...     URL directa del .sh (ignora GitHub)
# ============================================================

set -e

# ── Configura aquí tu repositorio ───────────────────────────
REPO="${KAFKA_INSTALLER_REPO:-cloudfactorybo/kafka-installer}"
SCRIPT_NAME="install-kafka-seguro.sh"
BRANCH_FALLBACK="main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

RUN_AFTER=0
for arg in "$@"; do
    case "$arg" in
        --run) RUN_AFTER=1 ;;
        -h|--help)
            sed -n '2,15p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
            exit 0 ;;
    esac
done

# ── Descarga genérica (curl o wget) ─────────────────────────
http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=30 "$1"
    else
        print_error "Se necesita curl o wget."
        exit 1
    fi
}

http_download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 60 "$1" -o "$2"
    else
        wget -q --timeout=60 "$1" -O "$2"
    fi
}

# ── Plataforma ──────────────────────────────────────────────
detect_platform() {
    case "$(uname -s)" in
        Linux*) ;;
        *) print_error "Sistema no soportado: $(uname -s). Solo Linux."; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  echo "linux_amd64" ;;
        aarch64|arm64) echo "linux_arm64" ;;
        *) print_error "Arquitectura no soportada: $(uname -m)."; exit 1 ;;
    esac
}

# ── Requisitos que el instalador va a necesitar ─────────────
check_requirements() {
    local faltan=0
    for cmd in docker openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            print_warning "Falta '$cmd' (el instalador lo necesitará)."
            faltan=1
        fi
    done
    if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        print_warning "Falta el plugin 'docker compose' v2."
        faltan=1
    fi
    [ $faltan -eq 0 ] && print_status "Requisitos OK: docker, docker compose, openssl"
    return 0
}

# ── Última versión publicada en GitHub ──────────────────────
get_latest_version() {
    local info tag
    info=$(http_get "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)
    tag=$(echo "$info" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    echo "$tag"
}

main() {
    print_status "Instalador de Kafka Seguro (TLS + SASL)"

    PLATFORM=$(detect_platform)
    print_status "Plataforma detectada: ${PLATFORM}"
    check_requirements

    INSTALL_DIR="$(pwd)"
    FINAL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
    TMP_FILE="$(mktemp)"
    trap 'rm -f "$TMP_FILE" "${TMP_FILE}.sha256"' EXIT

    # Elegir de dónde descargar
    if [ -n "$KAFKA_INSTALLER_URL" ]; then
        DOWNLOAD_URL="$KAFKA_INSTALLER_URL"
        VERSION="personalizada"
    else
        if [ "$REPO" = "TU_USUARIO/kafka-installer" ]; then
            print_error "Configura el repositorio: edita REPO en este script o usa KAFKA_INSTALLER_REPO=usuario/repo"
            exit 1
        fi
        VERSION="${KAFKA_INSTALLER_REF:-}"
        if [ -z "$VERSION" ]; then
            print_status "Consultando la última versión en GitHub..."
            VERSION=$(get_latest_version)
        fi
        if [ -n "$VERSION" ]; then
            DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${SCRIPT_NAME}"
        else
            print_warning "Sin releases publicadas; se usa la rama '${BRANCH_FALLBACK}'."
            VERSION="${BRANCH_FALLBACK}"
            DOWNLOAD_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH_FALLBACK}/${SCRIPT_NAME}"
        fi
    fi
    print_status "Versión: ${VERSION}"
    print_status "Descargando ${DOWNLOAD_URL}"

    http_download "$DOWNLOAD_URL" "$TMP_FILE" || { print_error "No se pudo descargar el instalador."; exit 1; }

    # Validaciones: no vacío, es bash, sintaxis correcta
    [ -s "$TMP_FILE" ] || { print_error "El archivo descargado está vacío."; exit 1; }
    head -1 "$TMP_FILE" | grep -q '^#!.*bash' || { print_error "El archivo descargado no es un script bash (¿URL incorrecta?)."; exit 1; }
    bash -n "$TMP_FILE" || { print_error "El script descargado tiene errores de sintaxis."; exit 1; }

    # Verificación de integridad si existe un .sha256 junto al script
    if http_download "${DOWNLOAD_URL}.sha256" "${TMP_FILE}.sha256" 2>/dev/null && [ -s "${TMP_FILE}.sha256" ]; then
        ESPERADO=$(awk '{print $1}' "${TMP_FILE}.sha256")
        OBTENIDO=$(sha256sum "$TMP_FILE" | awk '{print $1}')
        if [ "$ESPERADO" = "$OBTENIDO" ]; then
            print_status "Checksum SHA-256 verificado"
        else
            print_error "El checksum no coincide: el archivo pudo ser alterado. Se cancela."
            exit 1
        fi
    else
        print_warning "No hay archivo .sha256 publicado; no se verificó la integridad."
    fi

    # Respaldar una versión previa del instalador
    [ -f "$FINAL_PATH" ] && cp "$FINAL_PATH" "${FINAL_PATH}.bak" && print_status "Versión anterior guardada en ${FINAL_PATH}.bak"

    mv "$TMP_FILE" "$FINAL_PATH"
    chmod 755 "$FINAL_PATH"
    print_status "Instalador listo en ${FINAL_PATH}"

    if [ $RUN_AFTER -eq 1 ]; then
        print_status "Ejecutando instalador..."
        if [ "$(id -u)" -eq 0 ]; then
            exec "$FINAL_PATH" < /dev/tty
        else
            exec sudo "$FINAL_PATH" < /dev/tty
        fi
    else
        echo ""
        echo -e "   Siguiente paso:  ${GREEN}sudo ./${SCRIPT_NAME}${NC}"
        echo -e "   Versión de Kafka concreta:  ${GREEN}sudo ./${SCRIPT_NAME} --version 7.9.0${NC}"
    fi
}

main "$@"
