#!/usr/bin/env bash
set -euo pipefail

dir="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"
tmp="$(mktemp "$dir/.usuario.prom.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

escape() {
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

estado="${XDG_STATE_HOME:-$HOME/.local/state}/monitoreo"
exporter_url="${PODMAN_EXPORTER_URL:-http://127.0.0.1:9882/metrics}"
pausa_reinicio=600

# podman-exporter v1.21 con Podman 4.9 puede quedarse con la lista de contenedores vacía
# si arranca antes que ellos (p. ej. tras reiniciar el servidor) y no se recupera solo.
# Se reinicia cuando su cuenta no coincide con la de Podman en dos pasadas seguidas.
revisar_podman_exporter() {
  local podman_n exporter_n=-1 metricas antes ultimo=0 ahora
  podman_n="$(podman ps -a -q 2>/dev/null | wc -l)" || return 0
  # -1 = exporter inalcanzable: lo cubren Restart=always y ObjetivoCaido, no este reinicio.
  if metricas="$(curl -fsS --max-time 10 "$exporter_url" 2>/dev/null)"; then
    exporter_n="$(grep -c '^podman_container_info{' <<<"$metricas" || true)"
  fi
  ahora="$(date +%s)"
  mkdir -p "$estado"
  [[ -r "$estado/podman-exporter.ultimo-reinicio" ]] && ultimo="$(<"$estado/podman-exporter.ultimo-reinicio")"
  [[ "$ultimo" =~ ^[0-9]+$ ]] || ultimo=0

  if ((exporter_n >= 0 && exporter_n != podman_n)); then
    antes="$(cat "$estado/podman-exporter.desfase" 2>/dev/null || true)"
    if [[ -n "$antes" ]] && ((ahora - ultimo >= pausa_reinicio)); then
      systemctl --user restart --no-block mon-podman-exporter.service || true
      echo "$ahora" >"$estado/podman-exporter.ultimo-reinicio"
      ultimo="$ahora"
      rm -f "$estado/podman-exporter.desfase"
    else
      echo "$podman_n $exporter_n" >"$estado/podman-exporter.desfase"
    fi
  else
    rm -f "$estado/podman-exporter.desfase"
  fi

  echo '# HELP monitoreo_contenedores_podman Contenedores que lista podman ps -a.'
  echo '# TYPE monitoreo_contenedores_podman gauge'
  printf 'monitoreo_contenedores_podman %s\n' "$podman_n"
  echo '# HELP monitoreo_podman_exporter_ultimo_reinicio_segundos Momento del último reinicio automático de podman-exporter (0 = ninguno).'
  echo '# TYPE monitoreo_podman_exporter_ultimo_reinicio_segundos gauge'
  printf 'monitoreo_podman_exporter_ultimo_reinicio_segundos %s\n' "$ultimo"
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

  revisar_podman_exporter
} >"$tmp"

chmod 644 "$tmp"
mv -f "$tmp" "$dir/usuario.prom"
trap - EXIT
