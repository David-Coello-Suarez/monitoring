#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

require_non_root
purgar=false
[[ "${1:-}" == "--purge-datos" ]] && purgar=true

info "Deteniendo el monitoreo"
systemctl --user disable --now monitoreo-recolector.timer >/dev/null 2>&1 || true
rm -f "$USER_UNIT_DIR"/monitoreo-recolector.{service,timer}
systemctl --user daemon-reload
rm -f /var/lib/prometheus/node-exporter/usuario.prom

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  if $purgar; then
    kubectl delete namespace "$NAMESPACE" --wait=true >/dev/null
  else
    # Los PVC de los StatefulSet sobreviven a su borrado: así se conservan los datos.
    k delete statefulset,deployment,daemonset,configmap,secret,serviceaccount -l "$ETIQUETA" --wait=true >/dev/null
  fi
fi
kubectl delete clusterrole,clusterrolebinding -l "$ETIQUETA" --ignore-not-found >/dev/null

if $purgar; then
  info "Borrando datos y configuración"
  rm -rf "${CONF_DIR:?}" "${ALLOY_DIR:?}"/*
fi
ok "Monitoreo desinstalado. Los paquetes del host (node-exporter, cockpit) y k3s siguen instalados."
