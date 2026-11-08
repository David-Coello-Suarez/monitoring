#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

require_non_root

info "Servicios del monitoreo"
systemctl --user --no-pager --plain --no-legend list-units 'mon-*.service' 'monitoreo-recolector.*' |
  awk '{printf "    %-38s %s/%s\n", $1, $3, $4}'
for s in prometheus-node-exporter cockpit.socket; do
  printf '    %-38s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"
done

info "Objetivos de Prometheus"
curl -fsS http://127.0.0.1:9091/api/v1/targets 2>/dev/null | python3 -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    estado = {"up": "ok ", "unknown": " ? "}.get(t["health"], "MAL")
    print("    %s %-13s %s  %s" % (estado, t["labels"]["job"], t["scrapeUrl"], t.get("lastError", "")))
' || warn "Prometheus no responde"

info "Alertas activas"
curl -fsS 'http://127.0.0.1:9093/api/v2/alerts?active=true&silenced=false&inhibited=false' 2>/dev/null | python3 -c '
import json, sys
alertas = [a for a in json.load(sys.stdin) if a["labels"].get("alertname") != "Watchdog"]
for a in alertas:
    print("    [%s] %s: %s" % (a["labels"].get("severity", "?"), a["labels"]["alertname"], a["annotations"].get("summary", "")))
print("    ninguna" if not alertas else "")
' || warn "Alertmanager no responde"
