#!/usr/bin/env bash

set -Eeuo pipefail

readonly APP_NAME="vod-optimize"
readonly APP_URL="https://raw.githubusercontent.com/juniorfdtech/converter/refs/heads/main/vod-optimize.sh"
readonly INSTALL_PATH="/usr/local/bin/${APP_NAME}"

COLOR_BLUE='\033[1;34m'
COLOR_GREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'
COLOR_RESET='\033[0m'

log() {
    printf "%b[INFO]%b %s\n" "${COLOR_BLUE}" "${COLOR_RESET}" "$1"
}

success() {
    printf "%b[OK]%b %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$1"
}

warn() {
    printf "%b[AVISO]%b %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$1"
}

error() {
    printf "%b[ERRO]%b %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$1" >&2
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error "Este instalador precisa ser executado como root."
        echo
        echo "Use:"
        echo "  curl -fsSL https://raw.githubusercontent.com/juniorfdtech/converter/refs/heads/main/install-vod-optimize.sh | sudo bash"
        exit 1
    fi
}

install_dependencies() {
    if command -v apt-get >/dev/null 2>&1; then
        log "Detectado sistema baseado em Debian/Ubuntu."
        log "Atualizando índices de pacotes..."
        apt-get update

        log "Instalando dependências..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            ca-certificates \
            curl \
            ffmpeg

    elif command -v dnf >/dev/null 2>&1; then
        log "Detectado sistema baseado em Fedora/RHEL com DNF."
        log "Instalando dependências..."
        dnf install -y \
            ca-certificates \
            curl \
            ffmpeg

    elif command -v yum >/dev/null 2>&1; then
        log "Detectado sistema baseado em CentOS/RHEL com YUM."
        log "Instalando dependências..."
        yum install -y \
            ca-certificates \
            curl \
            ffmpeg

    elif command -v pacman >/dev/null 2>&1; then
        log "Detectado Arch Linux."
        log "Instalando dependências..."
        pacman -Sy --noconfirm \
            ca-certificates \
            curl \
            ffmpeg

    else
        error "Gerenciador de pacotes não suportado automaticamente."
        error "Instale manualmente: curl, ffmpeg e ca-certificates."
        exit 1
    fi
}

validate_dependencies() {
    local missing=0

    for cmd in curl ffmpeg ffprobe; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            error "Dependência não encontrada: ${cmd}"
            missing=1
        fi
    done

    if [[ ${missing} -ne 0 ]]; then
        exit 1
    fi
}

install_application() {
    local temp_file
    temp_file="$(mktemp)"

    cleanup() {
        rm -f "${temp_file}"
    }
    trap cleanup RETURN

    log "Baixando ${APP_NAME}..."

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 120 \
        "${APP_URL}" \
        --output "${temp_file}"

    if [[ ! -s "${temp_file}" ]]; then
        error "O arquivo baixado está vazio."
        exit 1
    fi

    if ! head -n 1 "${temp_file}" | grep -Eq '^#!.*bash'; then
        error "O arquivo baixado não possui um shebang Bash válido."
        exit 1
    fi

    if ! bash -n "${temp_file}"; then
        error "O script baixado contém erro de sintaxe."
        exit 1
    fi

    if [[ -f "${INSTALL_PATH}" ]]; then
        log "Versão existente encontrada em ${INSTALL_PATH}; ela será substituída."
    fi

    install \
        --owner=root \
        --group=root \
        --mode=0755 \
        "${temp_file}" \
        "${INSTALL_PATH}"

    if [[ ! -x "${INSTALL_PATH}" ]]; then
        error "Falha ao instalar ${APP_NAME} em ${INSTALL_PATH}."
        exit 1
    fi

    success "${APP_NAME} instalado em ${INSTALL_PATH}."
}

verify_installation() {
    echo
    log "Validando instalação..."

    printf "FFmpeg: "
    ffmpeg -version | head -n 1

    printf "FFprobe: "
    ffprobe -version | head -n 1

    printf "Executável: "
    command -v "${APP_NAME}"

    echo
    if "${INSTALL_PATH}" --help >/dev/null 2>&1; then
        success "O comando respondeu corretamente ao --help."
    else
        warn "O comando foi instalado, mas não respondeu ao --help."
        warn "Isso pode ser normal se a versão atual do vod-optimize não implementar --help."
    fi
}

main() {
    echo "============================================================"
    echo " ${APP_NAME} - Instalador"
    echo "============================================================"
    echo

    require_root
    install_dependencies
    validate_dependencies
    install_application
    verify_installation

    echo
    success "Instalação concluída."
    echo
    echo "Uso:"
    echo "  vod-optimize arquivo.mp4"
    echo "  vod-optimize /caminho/dos/videos"
    echo "  vod-optimize --profile balanced arquivo.mkv"
    echo "  vod-optimize --help"
    echo
    echo "Para atualizar, execute novamente este instalador."
}

main "$@"
