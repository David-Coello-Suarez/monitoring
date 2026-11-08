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

  echo '# HELP monitoreo_puerto_escucha Socket TCP en escucha en el host.'
  echo '# TYPE monitoreo_puerto_escucha gauge'
  ss -Htln | awk '{print $4}' | sort -u | while read -r local; do
    printf 'monitoreo_puerto_escucha{direccion="%s",puerto="%s"} 1\n' "$(escape "${local%:*}")" "${local##*:}"
  done
} >"$tmp"

chmod 644 "$tmp"
mv -f "$tmp" "$dir/usuario.prom"
trap - EXIT
