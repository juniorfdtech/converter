#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM="vod-optimize"
VERSION="1.0.0"

PROFILE="balanced"
FORCE=0
DISCARD_LARGER=0
OUTPUT_DIR=""
TARGET=""

log()  { printf '[%s] %s\n' "$1" "$2" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
die()  { log ERROR "$*"; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  vod-optimize.sh [opções] <arquivo-ou-diretório>

Opções:
  --profile quality|balanced|compact
      quality   : melhor qualidade / maior tempo e tamanho (SVT preset 4, CRF 24)
      balanced  : padrão recomendado (SVT preset 6, CRF 28)
      compact   : menor arquivo / mais perda (SVT preset 8, CRF 32)

  --output-dir DIR       Salva as saídas em DIR (mantém estrutura relativa em diretórios)
  --force                Sobrescreve a saída já existente
  --discard-larger       Descarta a conversão se o resultado ficar >= ao original
  -h, --help             Mostra esta ajuda
  --version              Mostra a versão

Exemplos:
  vod-optimize.sh filme.mp4
  vod-optimize.sh --profile quality /media/entrada
  vod-optimize.sh --profile compact --output-dir /media/convertidos /media/entrada

Saída padrão:
  arquivo.ext -> arquivo.av1.mkv

Observação:
  O script processa qualquer arquivo que o FFmpeg instalado consiga decodificar e que contenha
  uma faixa de vídeo. Arquivos sem vídeo são ignorados.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Dependência ausente: $1"
}

human_bytes() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " "); i=1;
    while (b >= 1024 && i < 5) { b/=1024; i++ }
    printf "%.2f %s", b, u[i]
  }'
}

parse_args() {
  while (($#)); do
    case "$1" in
      --profile)
        (($# >= 2)) || die "--profile exige um valor"
        PROFILE="$2"; shift 2 ;;
      --output-dir)
        (($# >= 2)) || die "--output-dir exige um diretório"
        OUTPUT_DIR="$2"; shift 2 ;;
      --force)
        FORCE=1; shift ;;
      --discard-larger)
        DISCARD_LARGER=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      --version)
        printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
      --)
        shift
        (($# == 1)) || die "Informe exatamente um arquivo ou diretório"
        TARGET="$1"; shift ;;
      -*)
        die "Opção desconhecida: $1" ;;
      *)
        [[ -z "$TARGET" ]] || die "Informe apenas um arquivo ou diretório por execução"
        TARGET="$1"; shift ;;
    esac
  done

  [[ -n "$TARGET" ]] || { usage; exit 2; }
  [[ -e "$TARGET" ]] || die "Caminho inexistente: $TARGET"

  case "$PROFILE" in
    quality|balanced|compact) ;;
    *) die "Perfil inválido: $PROFILE" ;;
  esac
}

select_video_encoder() {
  local encoders
  encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"

  if grep -qE '(^|[[:space:]])libsvtav1([[:space:]]|$)' <<<"$encoders"; then
    VIDEO_ENCODER="libsvtav1"
  elif grep -qE '(^|[[:space:]])libaom-av1([[:space:]]|$)' <<<"$encoders"; then
    VIDEO_ENCODER="libaom-av1"
    warn "libsvtav1 indisponível; usando libaom-av1 (consideravelmente mais lento)."
  else
    die "Seu FFmpeg não possui libsvtav1 nem libaom-av1. Instale uma build do FFmpeg com encoder AV1."
  fi

  if grep -qE '(^|[[:space:]])libopus([[:space:]]|$)' <<<"$encoders"; then
    AUDIO_ENCODER="libopus"
  else
    AUDIO_ENCODER="aac"
    warn "libopus indisponível; usando AAC como fallback."
  fi
}

profile_values() {
  case "$PROFILE" in
    quality)
      CRF=24; SVT_PRESET=4; AOM_CPU_USED=4 ;;
    balanced)
      CRF=28; SVT_PRESET=6; AOM_CPU_USED=6 ;;
    compact)
      CRF=32; SVT_PRESET=8; AOM_CPU_USED=8 ;;
  esac
}

has_video_stream() {
  ffprobe -v error -select_streams v:0 -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null | grep -q '[0-9]'
}

main_video_codec() {
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}

main_video_field_order() {
  ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}

main_video_pix_fmt() {
  ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}

main_video_transfer() {
  ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}

main_video_profile() {
  ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}

opus_bitrate_for_channels() {
  local channels="${1:-2}"
  case "$channels" in
    ''|*[!0-9]*) printf '128k' ;;
    1) printf '64k' ;;
    2) printf '112k' ;;
    3|4) printf '160k' ;;
    5|6) printf '224k' ;;
    7|8) printf '320k' ;;
    *) printf '384k' ;;
  esac
}

build_audio_args() {
  local input="$1"
  AUDIO_ARGS=()

  mapfile -t audio_rows < <(
    ffprobe -v error -select_streams a \
      -show_entries stream=codec_name,channels \
      -of csv=p=0 "$input" 2>/dev/null || true
  )

  local idx=0 codec channels bitrate row
  for row in "${audio_rows[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS=',' read -r codec channels <<<"$row"

    if [[ "$AUDIO_ENCODER" == "libopus" ]]; then
      if [[ "$codec" == "opus" ]]; then
        AUDIO_ARGS+=("-c:a:${idx}" copy)
      else
        bitrate="$(opus_bitrate_for_channels "$channels")"
        AUDIO_ARGS+=("-c:a:${idx}" libopus "-b:a:${idx}" "$bitrate" "-vbr:a:${idx}" on "-compression_level:a:${idx}" 10)
      fi
    else
      if [[ "$codec" == "aac" ]]; then
        AUDIO_ARGS+=("-c:a:${idx}" copy)
      else
        case "${channels:-2}" in
          1) bitrate="96k" ;;
          2) bitrate="160k" ;;
          *) bitrate="256k" ;;
        esac
        AUDIO_ARGS+=("-c:a:${idx}" aac "-b:a:${idx}" "$bitrate")
      fi
    fi

    ((idx+=1))
  done
}

build_subtitle_args() {
  local input="$1"
  SUBTITLE_ARGS=()

  mapfile -t subtitle_codecs < <(
    ffprobe -v error -select_streams s \
      -show_entries stream=codec_name \
      -of default=nw=1:nk=1 "$input" 2>/dev/null || true
  )

  local idx=0 codec
  for codec in "${subtitle_codecs[@]:-}"; do
    [[ -n "$codec" ]] || continue
    case "$codec" in
      mov_text|text|subrip|webvtt|microdvd|mpl2|jacosub|sami|realtext|subviewer|subviewer1|vplayer|pjs)
        SUBTITLE_ARGS+=("-c:s:${idx}" srt)
        ;;
      *)
        SUBTITLE_ARGS+=("-c:s:${idx}" copy)
        ;;
    esac
    ((idx+=1))
  done
}

output_path_for() {
  local input="$1"
  local base stem parent relative rel_parent
  base="$(basename -- "$input")"
  stem="${base%.*}"

  if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p -- "$OUTPUT_DIR"
    if [[ -d "$TARGET" ]]; then
      relative="${input#"${TARGET%/}/"}"
      rel_parent="$(dirname -- "$relative")"
      if [[ "$rel_parent" != "." ]]; then
        mkdir -p -- "$OUTPUT_DIR/$rel_parent"
        printf '%s/%s/%s.av1.mkv\n' "${OUTPUT_DIR%/}" "$rel_parent" "$stem"
      else
        printf '%s/%s.av1.mkv\n' "${OUTPUT_DIR%/}" "$stem"
      fi
    else
      printf '%s/%s.av1.mkv\n' "${OUTPUT_DIR%/}" "$stem"
    fi
  else
    parent="$(dirname -- "$input")"
    printf '%s/%s.av1.mkv\n' "$parent" "$stem"
  fi
}

validate_output() {
  local output="$1"
  [[ -s "$output" ]] || return 1
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=nw=1:nk=1 "$output" 2>/dev/null | grep -qx 'av1'
}

convert_one() {
  local input="$1" output partial source_codec field_order pix_fmt transfer profile_text
  local input_size output_size ratio
  local -a VIDEO_ARGS FILTER_ARGS COMMON_ARGS

  has_video_stream "$input" || { info "Ignorando sem vídeo: $input"; return 0; }

  output="$(output_path_for "$input")"
  partial="${output}.partial.$$"

  if [[ "$input" == "$output" ]]; then
    warn "Entrada e saída coincidem; ignorando: $input"
    return 0
  fi

  if [[ -e "$output" && "$FORCE" -ne 1 ]]; then
    info "Saída já existe; ignorando: $output"
    return 0
  fi

  mkdir -p -- "$(dirname -- "$output")"
  rm -f -- "$partial"

  source_codec="$(main_video_codec "$input")"
  field_order="$(main_video_field_order "$input")"
  pix_fmt="$(main_video_pix_fmt "$input")"
  transfer="$(main_video_transfer "$input")"
  profile_text="$(main_video_profile "$input")"

  info "Convertendo: $input"
  info "Vídeo: codec=${source_codec:-?}, pix_fmt=${pix_fmt:-?}, field_order=${field_order:-?}, transfer=${transfer:-?}, profile=${profile_text:-?}"

  if [[ "$transfer" == "smpte2084" || "$transfer" == "arib-std-b67" ]]; then
    warn "Fonte HDR detectada. HDR10/HLG costuma ser preservado, mas valide cores e metadados no dispositivo final."
  fi
  if grep -qi 'Dolby Vision' <<<"$profile_text"; then
    warn "Dolby Vision detectado: a recodificação AV1 genérica pode não preservar metadados dinâmicos Dolby Vision."
  fi

  FILTER_ARGS=()
  case "${field_order:-progressive}" in
    progressive|unknown|'') ;;
    *)
      FILTER_ARGS=(-vf "bwdif=mode=send_frame:parity=auto:deint=interlaced")
      info "Conteúdo interlaçado detectado; aplicando bwdif."
      ;;
  esac

  if [[ "$source_codec" == "av1" ]]; then
    VIDEO_ARGS=(-c:v copy)
    info "Vídeo já está em AV1; copiando sem perda geracional."
  elif [[ "$VIDEO_ENCODER" == "libsvtav1" ]]; then
    VIDEO_ARGS=(-c:v libsvtav1 -crf "$CRF" -preset "$SVT_PRESET" -pix_fmt yuv420p10le)
  else
    VIDEO_ARGS=(-c:v libaom-av1 -crf "$CRF" -b:v 0 -cpu-used "$AOM_CPU_USED" -row-mt 1 -pix_fmt yuv420p10le)
  fi

  build_audio_args "$input"
  build_subtitle_args "$input"

  COMMON_ARGS=(
    -hide_banner -nostdin -y
    -i "$input"
    -map 0:v:0
    -map 0:a?
    -map 0:s?
    -map 0:t?
    -map_metadata 0
    -map_chapters 0
    -c:t copy
    -max_muxing_queue_size 4096
  )

  # Não aplique filtro quando o vídeo for stream-copy.
  if [[ "${VIDEO_ARGS[*]}" == *"-c:v copy"* ]]; then
    FILTER_ARGS=()
  fi

  set +e
  ffmpeg "${COMMON_ARGS[@]}" \
    "${FILTER_ARGS[@]}" \
    "${VIDEO_ARGS[@]}" \
    "${AUDIO_ARGS[@]}" \
    "${SUBTITLE_ARGS[@]}" \
    -f matroska "$partial"
  local ffmpeg_rc=$?
  set -e

  if ((ffmpeg_rc != 0)); then
    rm -f -- "$partial"
    warn "Falha na conversão: $input"
    return 1
  fi

  if ! validate_output "$partial"; then
    rm -f -- "$partial"
    warn "Saída inválida ou sem vídeo AV1: $input"
    return 1
  fi

  input_size="$(stat -c '%s' -- "$input")"
  output_size="$(stat -c '%s' -- "$partial")"

  if ((DISCARD_LARGER == 1 && output_size >= input_size)); then
    rm -f -- "$partial"
    warn "Resultado não ficou menor; descartado. Entrada=$(human_bytes "$input_size"), saída=$(human_bytes "$output_size")"
    return 0
  fi

  mv -f -- "$partial" "$output"
  ratio="$(awk -v i="$input_size" -v o="$output_size" 'BEGIN { if (i>0) printf "%.1f", (1-(o/i))*100; else print "0.0" }')"

  info "Concluído: $output"
  info "Tamanho: $(human_bytes "$input_size") -> $(human_bytes "$output_size") | redução=${ratio}%"
}

process_target() {
  local failures=0

  if [[ -f "$TARGET" ]]; then
    convert_one "$TARGET" || failures=$((failures + 1))
  else
    while IFS= read -r -d '' file; do
      # Evita reprocessar saídas geradas pelo próprio script.
      [[ "$file" == *.av1.mkv ]] && continue
      convert_one "$file" || failures=$((failures + 1))
    done < <(find "$TARGET" -type f ! -name '*.av1.mkv' ! -name '*.partial.*' -print0)
  fi

  if ((failures > 0)); then
    die "$failures arquivo(s) falharam. Revise as mensagens acima."
  fi
}

main() {
  parse_args "$@"
  require_cmd ffmpeg
  require_cmd ffprobe
  require_cmd awk
  require_cmd stat
  require_cmd find

  select_video_encoder
  profile_values

  info "$PROGRAM $VERSION"
  info "Perfil=$PROFILE | encoder=$VIDEO_ENCODER | áudio=$AUDIO_ENCODER | CRF=$CRF"
  process_target
}

main "$@"
