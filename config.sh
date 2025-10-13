#!/usr/bin/env bash
set -euo pipefail

# === Rutas base (tu repo) ===
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Carpeta por streamer (como pediste)
# clave = carpeta final donde van los .vtt de ese canal
declare -A CHANNELS=(
  # Javi Oliveira
  ["javioliveira/javiOliveira"]="https://www.youtube.com/@JaviOliveira"
  ["javioliveira/lasalseria"]="https://www.youtube.com/@javielcanijo"
  ["javioliveira/telesalseo"]="https://www.youtube.com/@tvsalseo"

  # Dalas
  ["dalas/DalasReview"]="https://www.youtube.com/@DalasReview"
  ["dalas/DalasSinFiltros"]="https://www.youtube.com/@DTeamVlogs"

  # Frank Cuesta
  ["frankcuesta/frank"]="https://www.youtube.com/@santuariolibertad"
)

# Subs a intentar
SUB_LANGS="es.*,en.*"
SUB_FMT="vtt"

# Cookies (opcional): export COOKIES_FILE=/ruta/cookies.txt
export COOKIES_FILE="/apps/molder/get-channel-lists/cookies.txt"

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*" >&2; }

yt_dlp_cmd() {
  if [[ -n "$COOKIES_FILE" && -f "$COOKIES_FILE" ]]; then
    yt-dlp --cookies "$COOKIES_FILE" "$@"
  else
    yt-dlp "$@"
  fi
}

# Igual que --restrict-filenames de yt-dlp (suficiente para glob)
sanitize_glob() {
  local t="$1"
  t="${t//$'\r'/ }"
  t="${t//$'\n'/ }"
  t="$(printf '%s' "$t" \
      | tr -s '[:space:]' '_' \
      | sed -E 's/[^A-Za-z0-9._-]/_/g')"
  echo "$t"
}

