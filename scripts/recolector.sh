#!/usr/bin/env bash
set -euo pipefail

dir="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"
tmp="$(mktemp "$dir/.usuario.prom.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

escape() {
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

{
  echo '# HELP monitoreo_unidad_usuario Estado de cada servicio systemd del usuario.'
  echo '# TYPE monitoreo_unidad_usuario gauge'
  systemctl --user list-units --type=service --all --plain --no-legend --no-pager |
    sed 's/^[^[:alnum:]@_.-]*//' |
    while read -r unit load active sub _; do
      [[ -n "$unit" ]] || continue
      [[ "$unit" =~ ^[0-9a-f]{64}\.(service|timer)$ ]] && continue
      # Mientras corre, el propio recolector siempre sale "activating": se omite.
      [[ "$unit" == monitoreo-recolector.service ]] && continue
      printf 'monitoreo_unidad_usuario{unit="%s",load="%s",active="%s",sub="%s"} 1\n' \
        "$(escape "$unit")" "$load" "$active" "$sub"
    done

  echo '# HELP monitoreo_servidor_info Datos del equipo que node-exporter no publica.'
  echo '# TYPE monitoreo_servidor_info gauge'
  cpu_modelo="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p;T;q' /proc/cpuinfo)"
  ruta="$(ip -4 -o route get 1.1.1.1 2>/dev/null || true)"
  ip_lan="$(sed -n 's/.* src \([0-9.]*\).*/\1/p' <<<"$ruta")"
  puerta="$(sed -n 's/.* via \([0-9.]*\).*/\1/p' <<<"$ruta")"
  interfaz="$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$ruta")"
  printf 'monitoreo_servidor_info{cpu_modelo="%s",ip_lan="%s",puerta_enlace="%s",interfaz="%s"} 1\n' \
    "$(escape "$cpu_modelo")" "$ip_lan" "$puerta" "$interfaz"

  repo_orches="$HOME/.config/orches/repo"
  if [[ -d "$repo_orches/.git" ]]; then
    commit="$(git -C "$repo_orches" log -1 --format=%H 2>/dev/null || true)"
    fecha="$(git -C "$repo_orches" log -1 --format=%ct 2>/dev/null || echo 0)"
    asunto="$(git -C "$repo_orches" log -1 --format=%s 2>/dev/null || true)"
    remoto="$(timeout 10 git -C "$repo_orches" ls-remote origin HEAD 2>/dev/null | cut -f1 || true)"
    diario="$(journalctl --user -u orches.service --since -7d -o short-unix --no-pager 2>/dev/null || true)"
    revision="$(grep -E 'No new commits to sync|Added:|Modified:|Removed:|Initialized repo' <<<"$diario" | tail -1 | cut -d' ' -f1 || true)"
    cambio="$(grep -E 'Added:|Modified:|Removed:' <<<"$diario" | tail -1 | cut -d' ' -f1 || true)"
    desde=$(($(date +%s) - 600))
    errores="$(awk -v d="$desde" '$1 >= d && tolower($0) ~ /error|failed/' <<<"$diario" | wc -l)"

    echo '# HELP monitoreo_orches_info Commit que orches tiene desplegado.'
    echo '# TYPE monitoreo_orches_info gauge'
    printf 'monitoreo_orches_info{commit="%s",asunto="%s"} 1\n' "${commit:0:12}" "$(escape "$asunto")"
    echo '# HELP monitoreo_orches_commit_fecha_segundos Fecha del commit desplegado.'
    echo '# TYPE monitoreo_orches_commit_fecha_segundos gauge'
    printf 'monitoreo_orches_commit_fecha_segundos %s\n' "$fecha"
    echo '# HELP monitoreo_orches_remoto_ok 1 si GitHub respondió a git ls-remote.'
    echo '# TYPE monitoreo_orches_remoto_ok gauge'
    printf 'monitoreo_orches_remoto_ok %s\n' "$([[ -n "$remoto" ]] && echo 1 || echo 0)"
    if [[ -n "$remoto" ]]; then
      echo '# HELP monitoreo_orches_remoto_info Último commit de la rama en GitHub.'
      echo '# TYPE monitoreo_orches_remoto_info gauge'
      printf 'monitoreo_orches_remoto_info{commit="%s"} 1\n' "${remoto:0:12}"
      echo '# HELP monitoreo_orches_sincronizado 1 si el commit desplegado es el último de GitHub.'
      echo '# TYPE monitoreo_orches_sincronizado gauge'
      printf 'monitoreo_orches_sincronizado %s\n' "$([[ "$remoto" == "$commit" ]] && echo 1 || echo 0)"
    fi
    if [[ -n "$revision" ]]; then
      echo '# HELP monitoreo_orches_ultima_revision_segundos Última vez que orches revisó el repositorio.'
      echo '# TYPE monitoreo_orches_ultima_revision_segundos gauge'
      printf 'monitoreo_orches_ultima_revision_segundos %s\n' "${revision%.*}"
    fi
    if [[ -n "$cambio" ]]; then
      echo '# HELP monitoreo_orches_ultimo_cambio_segundos Último cambio aplicado (alta, modificación o baja de unidades).'
      echo '# TYPE monitoreo_orches_ultimo_cambio_segundos gauge'
      printf 'monitoreo_orches_ultimo_cambio_segundos %s\n' "${cambio%.*}"
    fi
    echo '# HELP monitoreo_orches_errores_10m Líneas de error de orches en los últimos 10 minutos.'
    echo '# TYPE monitoreo_orches_errores_10m gauge'
    printf 'monitoreo_orches_errores_10m %s\n' "$errores"
    echo '# HELP monitoreo_orches_unidad Unidades de la raíz del repositorio que gestiona orches.'
    echo '# TYPE monitoreo_orches_unidad gauge'
    for f in "$repo_orches"/*.container "$repo_orches"/*.network "$repo_orches"/*.service; do
      [[ -e "$f" ]] || continue
      nombre="$(basename "$f")"
      case "$nombre" in
        *.container) unidad="${nombre%.container}.service" ;;
        *.network) unidad="${nombre%.network}-network.service" ;;
        *) unidad="$nombre" ;;
      esac
      printf 'monitoreo_orches_unidad{unit="%s",archivo="%s"} 1\n' "$(escape "$unidad")" "$(escape "$nombre")"
    done
  fi

  echo '# HELP monitoreo_puerto_escucha Socket TCP en escucha en el host.'
  echo '# TYPE monitoreo_puerto_escucha gauge'
  ss -Htln | awk '{print $4}' | sort -u | while read -r local; do
    printf 'monitoreo_puerto_escucha{direccion="%s",puerto="%s"} 1\n' "$(escape "${local%:*}")" "${local##*:}"
  done
} >"$tmp"

chmod 644 "$tmp"
mv -f "$tmp" "$dir/usuario.prom"
trap - EXIT
