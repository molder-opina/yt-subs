#!/usr/bin/env bash
set -euo pipefail

# === Configuración ===
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

declare -A CHANNELS=(
  # Cada clave ES la carpeta final donde quieres los .vtt de ese canal
  # Javi Oliveira (3 canales)
  ["javiOliveiraSubtitulos/javiOliveira"]="https://www.youtube.com/@JaviOliveira"
  ["javiOliveiraSubtitulos/lasalseria"]="https://www.youtube.com/@javielcanijo"
  ["javiOliveiraSubtitulos/telesalseo"]="https://www.youtube.com/@tvsalseo"

  # Dalas (2 canales)
  ["dalasSubtitulos/DalasReview"]="https://www.youtube.com/@DalasReview"
  ["dalasSubtitulos/DalasSinFiltros"]="https://www.youtube.com/@DTeamVlogs"

  # Frank Cuesta (1 canal)
  ["frankCuestaSubtitulos/frank"]="https://www.youtube.com/@santuariolibertad"
)

SUB_LANGS="es.*,en.*"
SUB_FMT="vtt"
COOKIES_FILE="${COOKIES_FILE:-}"   # opcional: export COOKIES_FILE=/ruta/cookies.txt

# === Utilidades ===
log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*" >&2; }

yt_dlp_cmd() {
  if [[ -n "$COOKIES_FILE" && -f "$COOKIES_FILE" ]]; then
    yt-dlp --cookies "$COOKIES_FILE" "$@"
  else
    yt-dlp "$@"
  fi
}

# Sanea texto a patrón/glob compatible con --restrict-filenames
sanitize_glob() {
  local t="$1"
  t="${t//$'\r'/ }"
  t="${t//$'\n'/ }"
  t="$(printf '%s' "$t" \
      | tr -s '[:space:]' '_' \
      | sed -E 's/[^A-Za-z0-9._-]/_/g')"
  echo "$t"
}

# Descarga subtítulos con nombre: Titulo_saneado.(lang).vtt
download_subs_for_id() {
  local video_id="$1"
  local dest_dir="$2"
  yt_dlp_cmd \
    --no-warnings \
    --restrict-filenames \
    --trim-filenames 200 \
    --skip-download \
    --write-auto-subs --write-subs \
    --sub-lang "$SUB_LANGS" \
    --sub-format "$SUB_FMT" \
    -o "$dest_dir/%(title).200B.%(lang)s.%(ext)s" \
    "https://www.youtube.com/watch?v=${video_id}"
}

any_vtt_in_dir() {
  local d="$1"
  shopt -s nullglob
  local arr=( "$d"/*.vtt )
  shopt -u nullglob
  (( ${#arr[@]} > 0 ))
}

# Devuelve el título (col 2) de un ID (col 1) buscándolo en un TSV id<TAB>title
title_for_id_from_tsv() {
  local id="$1" tsv="$2"
  awk -F'\t' -v VID="$id" '$1==VID { $1=""; sub(/^\t/,""); print; exit }' "$tsv"
}

# === Proceso por canal ===
process_channel() {
  local rel_dir="$1" url="$2"

  # Carpeta FINAL del canal (tal cual la clave en CHANNELS)
  local dest="${BASE_DIR}/${rel_dir}"
  local state="${dest}/.state"
  local elim_dir="${dest}/eliminados"
  local elim_log="${dest}/eliminados.log"   # acumulativo
  local ts; ts="$(date +'%F_%H%M%S')"

  mkdir -p "$dest" "$state" "$elim_dir"

  local current_tsv="${state}/current_${ts}.tsv"
  local last_tsv="${state}/last.tsv"
  local vanished_ids="${state}/vanished_ids_${ts}.txt"

  log "Canal: $rel_dir"
  log "URL:   $url"
  log "Carpeta: $dest"

  # 1) Listado actual (ID \t Título)
  yt_dlp_cmd --flat-playlist --print "%(id)s\t%(title)s" "$url" \
    | sed '/^\s*$/d' > "$current_tsv"

  if [[ ! -s "$current_tsv" ]]; then
    log "Advertencia: no se obtuvo listado para $url (vacío)."
    return 0
  fi

  # 2) Baseline: si NO existe -> crear vacío (no bloquea descargas)
  if [[ ! -f "$last_tsv" ]]; then
    : > "$last_tsv"
    log "Primera ejecución para este canal (no hay baseline previo)."
  fi

  # 3) Determinar si la carpeta está vacía (sin .vtt): inicializar TODO
  local initial_sync=0
  if ! any_vtt_in_dir "$dest"; then
    initial_sync=1
    log "Carpeta sin .vtt → poblar con TODO lo disponible del listado actual."
  fi

  # 4) ELIMINADOS (solo si ya hay baseline previo con IDs)
  cut -f1 "$current_tsv" | LC_ALL=C sort -u > "${state}/ids_now.txt"
  cut -f1 "$last_tsv"    | LC_ALL=C sort -u > "${state}/ids_prev.txt"
  if [[ -s "${state}/ids_prev.txt" ]]; then
    comm -23 "${state}/ids_prev.txt" "${state}/ids_now.txt" > "$vanished_ids"
  else
    : > "$vanished_ids"
  fi

  # 5) DESCARGA:
  #    - Si initial_sync=1: baja TODO (cada video del listado).
  #    - Si no: solo lo que falte (ni título actual ni anterior existen).
  log "Comprobando subtítulos a descargar…"
  while IFS=$'\t' read -r vid vtitle; do
    [[ -z "${vid:-}" || -z "${vtitle:-}" ]] && continue

    local safe_now; safe_now="$(sanitize_glob "$vtitle")"
    local need_download=0

    if (( initial_sync )); then
      need_download=1
    else
      # ¿Existen .vtt con el título ACTUAL?
      shopt -s nullglob
      local now_matches=( "$dest/${safe_now}".*.vtt )
      shopt -u nullglob
      if (( ${#now_matches[@]} == 0 )); then
        # ¿Existen .vtt con el TÍTULO ANTERIOR de ESTE ID?
        local prev_title; prev_title="$(title_for_id_from_tsv "$vid" "$last_tsv" || true)"
        if [[ -n "$prev_title" ]]; then
          local safe_prev; safe_prev="$(sanitize_glob "$prev_title")"
          shopt -s nullglob
          local prev_matches=( "$dest/${safe_prev}".*.vtt )
          shopt -u nullglob
          if (( ${#prev_matches[@]} == 0 )); then
            need_download=1
          fi
        else
          need_download=1
        fi
      fi
    fi

    if (( need_download )); then
      log "Descargando subtítulos: [$vid] $vtitle"
      if ! download_subs_for_id "$vid" "$dest"; then
        log "ERROR al descargar subtítulos para $vid | $vtitle"
      fi
    fi
  done < "$current_tsv"

  # 6) ELIMINADOS: mover y registrar en eliminados.log
  if [[ -s "$vanished_ids" ]]; then
    local batch="${elim_dir}/${ts}"
    mkdir -p "$batch"
    local moved=0

    while IFS= read -r old_id; do
      [[ -z "$old_id" ]] && continue
      local old_title; old_title="$(title_for_id_from_tsv "$old_id" "$last_tsv" || true)"
      [[ -z "$old_title" ]] && continue

      local safe_old; safe_old="$(sanitize_glob "$old_title")"

      shopt -s nullglob
      local matches=( "$dest/${safe_old}".*.vtt )
      shopt -u nullglob

      if (( ${#matches[@]} > 0 )); then
        for f in "${matches[@]}"; do mv -f -- "$f" "$batch/"; ((moved++)) || true; done
        log "Movido a eliminados: [$old_id] «$old_title» (${#matches[@]} archivo/s)"
      fi

      # Registrar acumulativamente (fecha, id, título original)
      printf "%s\t%s\t%s\n" "$(date +'%F %T')" "$old_id" "$old_title" >> "$elim_log"
    done < "$vanished_ids"

    if (( moved == 0 )); then
      log "No había archivos locales correspondientes a los IDs desaparecidos."
    fi
  else
    log "No hay IDs desaparecidos respecto a la última ejecución."
  fi

  # 7) Actualiza baseline al final
  cp -f "$current_tsv" "$last_tsv"
  log "Canal listo en: $dest"
}

# === MAIN ===
main() {
  cd "$BASE_DIR"

  # Validación: que no existan claves repetidas en CHANNELS
  declare -A seen=()
  for rel in "${!CHANNELS[@]}"; do
    if [[ -n "${seen[$rel]:-}" ]]; then
      log "ERROR: carpeta repetida en CHANNELS: $rel"
      exit 1
    fi
    seen["$rel"]=1
  done
  unset seen

  for rel in "${!CHANNELS[@]}"; do
    process_channel "$rel" "${CHANNELS[$rel]}"
  done
  log "Proceso completado."
}

main "$@"

