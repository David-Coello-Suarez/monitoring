#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

ahora="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fin="$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
curl -fsS -X POST -H 'Content-Type: application/json' http://127.0.0.1:9093/api/v2/alerts -d "[{
  \"labels\": {\"alertname\": \"PruebaDeAlerta\", \"severity\": \"warning\", \"servidor\": \"$(hostname)\"},
  \"annotations\": {\"summary\": \"Mensaje de prueba enviado por probar-alerta.sh\"},
  \"startsAt\": \"$ahora\",
  \"endsAt\": \"$fin\"
}]" >/dev/null
ok "Alerta de prueba enviada. Debe llegar a Telegram en unos 30 s y resolverse en 5 min."
