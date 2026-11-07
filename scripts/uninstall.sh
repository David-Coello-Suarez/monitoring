#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

require_non_root
purgar=false
[[ "${1:-}" == "--purge-datos" ]] && purgar=true

info "Deteniendo el monitoreo"
systemctl --user disable --now monitoreo-recolector.timer >/dev/null 2>&1 || true
for f in "$QUADLET_DIR"/mon-*.container; do
  [[ -e "$f" ]] || continue
  systemctl --user stop "$(basename "${f%.container}").service" || true
  rm -f "$f"
done
rm -f "$USER_UNIT_DIR"/monitoreo-recolector.{service,timer}
systemctl --user daemon-reload
rm -f /var/lib/prometheus/node-exporter/usuario.prom

for s in mon-telegram-token mon-grafana-admin mon-pg-password; do
  podman secret rm "$s" >/dev/null 2>&1 || true
done

if $purgar; then
  info "Borrando volúmenes y configuración"
  for v in mon-prometheus mon-alertmanager mon-loki mon-alloy mon-grafana; do
    podman volume rm "$v" >/dev/null 2>&1 || true
  done
  rm -rf "${CONF_DIR:?}"
fi
ok "Monitoreo desinstalado. Los paquetes del host (node-exporter, cockpit) siguen instalados."
