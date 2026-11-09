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

  estados="" saludes="" arranques=""
  while IFS='|' read -r nombre estado salud inicio imagen; do
    [[ -n "$nombre" ]] || continue
    etiquetas="name=\"$(escape "${nombre#/}")\",image=\"$(escape "$imagen")\""
    case "$estado" in
      created) n_estado=0 ;;
      running) n_estado=2 ;;
      paused) n_estado=4 ;;
      exited | dead) n_estado=5 ;;
      removing) n_estado=6 ;;
      restarting) n_estado=7 ;;
      *) n_estado=-1 ;;
    esac
    case "$salud" in
      healthy) n_salud=0 ;;
      unhealthy) n_salud=1 ;;
      starting) n_salud=2 ;;
      *) n_salud=-1 ;;
    esac
    estados+="monitoreo_contenedor_estado{$etiquetas} $n_estado"$'\n'
    saludes+="monitoreo_contenedor_salud{$etiquetas} $n_salud"$'\n'
    arranques+="monitoreo_contenedor_arranque_segundos{$etiquetas} $(date -d "$inicio" +%s)"$'\n'
  done < <(docker ps -aq | xargs -r docker inspect --format '{{.Name}}|{{.State.Status}}|{{with .State.Health}}{{.Status}}{{end}}|{{.State.StartedAt}}|{{.Config.Image}}')
  echo '# HELP monitoreo_contenedor_estado Estado del contenedor: 0 creado, 2 corriendo, 4 pausado, 5 salio, 6 borrando, 7 reiniciando.'
  echo '# TYPE monitoreo_contenedor_estado gauge'
  printf '%s' "$estados"
  echo '# HELP monitoreo_contenedor_salud Healthcheck del contenedor: -1 sin healthcheck, 0 sano, 1 enfermo, 2 arrancando.'
  echo '# TYPE monitoreo_contenedor_salud gauge'
  printf '%s' "$saludes"
  echo '# HELP monitoreo_contenedor_arranque_segundos Hora del ultimo arranque del contenedor.'
  echo '# TYPE monitoreo_contenedor_arranque_segundos gauge'
  printf '%s' "$arranques"

  echo '# HELP monitoreo_docker_info Versiones de Docker.'
  echo '# TYPE monitoreo_docker_info gauge'
  printf 'monitoreo_docker_info{docker="%s",runtime="%s",compose="%s"} 1\n' \
    "$(docker version --format '{{.Server.Version}}')" \
    "$(docker version --format '{{range .Server.Components}}{{if eq .Name "runc"}}runc {{.Version}}{{end}}{{end}}')" \
    "$(docker compose version --short)"

  echo '# HELP monitoreo_puerto_escucha Socket TCP en escucha en el host.'
  echo '# TYPE monitoreo_puerto_escucha gauge'
  ss -Htln | awk '{print $4}' | sort -u | while read -r local; do
    printf 'monitoreo_puerto_escucha{direccion="%s",puerto="%s"} 1\n' "$(escape "${local%:*}")" "${local##*:}"
  done
} >"$tmp"

chmod 644 "$tmp"
mv -f "$tmp" "$dir/usuario.prom"
trap - EXIT
