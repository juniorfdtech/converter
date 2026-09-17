#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP="vod-optimize"
DEST="/usr/local/bin/${APP}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/vod-optimize.sh"

log() { printf '[%s] %s\n' "$1" "$2" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
die() { log ERROR "$*"; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ $EUID -eq 0 ]]; then
    rm -f -- "$DEST"
  elif command -v sudo >/dev/null 2>&1; then
    sudo rm -f -- "$DEST"
  else
    die "É necessário root ou sudo para remover $DEST"
  fi
  info "Removido: $DEST"
  exit 0
fi

[[ -f "$SOURCE" ]] || die "vod-optimize.sh não encontrado ao lado do instalador."

if [[ $EUID -eq 0 ]]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  die "Execute como root ou instale sudo."
fi

install_ffmpeg() {
  if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    info "FFmpeg já está instalado."
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    info "Instalando FFmpeg via APT..."
    "${SUDO[@]}" apt-get update
    DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y ffmpeg
  elif command -v dnf >/dev/null 2>&1; then
    info "Instalando FFmpeg via DNF..."
    "${SUDO[@]}" dnf install -y ffmpeg
  elif command -v pacman >/dev/null 2>&1; then
    info "Instalando FFmpeg via Pacman..."
    "${SUDO[@]}" pacman -Sy --noconfirm ffmpeg
  elif command -v apk >/dev/null 2>&1; then
    info "Instalando FFmpeg via APK..."
    "${SUDO[@]}" apk add --no-cache ffmpeg
  else
    die "Gerenciador de pacotes não reconhecido. Instale FFmpeg/ffprobe manualmente e rode novamente."
  fi
}

validate_ffmpeg() {
  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg não encontrado após instalação."
  command -v ffprobe >/dev/null 2>&1 || die "ffprobe não encontrado após instalação."

  local encoders
  encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"

  if grep -qE '(^|[[:space:]])libsvtav1([[:space:]]|$)' <<<"$encoders"; then
    info "Encoder AV1: libsvtav1 (recomendado)."
  elif grep -qE '(^|[[:space:]])libaom-av1([[:space:]]|$)' <<<"$encoders"; then
    warn "libsvtav1 não encontrado; libaom-av1 será usado como fallback."
  else
    die "A build instalada do FFmpeg não possui libsvtav1 nem libaom-av1. Instale uma build com suporte a AV1."
  fi

  if grep -qE '(^|[[:space:]])libopus([[:space:]]|$)' <<<"$encoders"; then
    info "Áudio: libopus disponível."
  else
    warn "libopus não encontrado. O conversor usará AAC como fallback."
  fi
}

install_app() {
  "${SUDO[@]}" install -m 0755 -- "$SOURCE" "$DEST"
  info "Instalado: $DEST"
}

download_script() {
	sudo curl -fL "https://raw.githubusercontent.com/juniorfdtech/converter/refs/heads/main/vod-optimize.sh" -o /usr/local/bin/vod-optimize
	sudo chmod 755 /usr/local/bin/vod-optimize
	cat /dev/null > ~/.bash_history && history -c && clear
}

install_ffmpeg
validate_ffmpeg
install_app
download_script

printf '\nInstalação concluída.\n\n'
printf 'Uso:\n'
printf '  vod-optimize filme.mp4\n'
printf '  vod-optimize --profile quality /pasta/videos\n'
printf '  vod-optimize --profile compact --output-dir /pasta/saida /pasta/entrada\n\n'
printf 'Ajuda:\n'
printf '  vod-optimize --help\n'
