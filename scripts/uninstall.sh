#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

require_non_root
purgar=false
[[ "${1:-}" == "--purge-datos" ]] && purgar=true

info "Deteniendo el monitoreo"
systemctl --user disable --now monitoreo-recolector.timer >/dev/null 2>&1 || true
if [[ -f "$CONF_DIR/compose.env" ]]; then
  COMPOSE_PROFILES=postgres dc down --remove-orphans || true
fi
rm -f "$USER_UNIT_DIR"/monitoreo-recolector.{service,timer}
systemctl --user daemon-reload
rm -f /var/lib/prometheus/node-exporter/usuario.prom

if $purgar; then
  info "Borrando datos y configuración"
  rm -rf "${DATOS_DIR:?}" "${CONF_DIR:?}"
fi
ok "Monitoreo desinstalado. Los paquetes del host (node-exporter, cockpit) siguen instalados."
