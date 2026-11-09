#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

SECRETOS_DIR="$CONF_DIR/secretos"

require_non_root
require_cmd docker systemctl systemd-run curl ss sed
require_user_systemd
require_docker
load_env

[[ -n "${TELEGRAM_CHAT_ID:-}" ]] || die "TELEGRAM_CHAT_ID está vacío en .env"
[[ -d /var/lib/prometheus/node-exporter && -w /var/lib/prometheus/node-exporter ]] ||
  die "falta el lado host. Ejecuta primero: sudo ./scripts/install-host.sh"
systemd-run --user --wait --quiet --collect docker version >/dev/null 2>&1 ||
  die "systemd --user no ve el grupo docker. Ejecuta: sudo systemctl restart user@$(id -u).service y vuelve a entrar."

usar_postgres=false
if [[ -n "${POSTGRES_CONTENEDOR:-}" ]]; then
  if docker container inspect "$POSTGRES_CONTENEDOR" >/dev/null 2>&1; then
    usar_postgres=true
  else
    warn "no existe el contenedor $POSTGRES_CONTENEDOR: no instalo postgres-exporter"
  fi
fi

generar_clave() {
  # Con tr </dev/urandom | head, tr muere por SIGPIPE y pipefail aborta sin mensaje.
  local n="${1:-32}" s
  s="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  ((${#s} >= n)) || die "no se pudo generar una clave aleatoria"
  printf '%s' "${s:0:n}"
}

info "Secretos"
install -d -m 0700 "$SECRETOS_DIR"
if [[ ! -s "$SECRETOS_DIR/telegram-token" ]]; then
  read -rsp "Token del bot de Telegram (no se muestra): " token
  echo
  [[ -n "$token" ]] || die "token vacío"
  (umask 077 && printf '%s' "$token" >"$SECRETOS_DIR/telegram-token")
  unset token
fi
if [[ ! -s "$SECRETOS_DIR/grafana-admin" ]]; then
  (umask 077 && generar_clave 24 >"$SECRETOS_DIR/grafana-admin")
fi
ok "telegram y grafana"

if $usar_postgres; then
  [[ -s "$SECRETOS_DIR/pg-password" ]] || (umask 077 && generar_clave 32 >"$SECRETOS_DIR/pg-password")
  {
    printf "\\set clave '%s'\n" "$(cat "$SECRETOS_DIR/pg-password")"
    cat <<'SQL'
SET client_min_messages = warning;
SELECT 'CREATE ROLE monitoreo LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitoreo')\gexec
ALTER ROLE monitoreo WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'clave';
GRANT pg_monitor TO monitoreo;
SQL
  } | docker exec -i "$POSTGRES_CONTENEDOR" sh -c 'psql -q -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"' >/dev/null
  ok "rol monitoreo (pg_monitor) en $POSTGRES_CONTENEDOR"
fi

USAR_POSTGRES="$usar_postgres" "$REPO_DIR/scripts/generar-config.sh"

info "Datos"
install -d -m 0700 "$DATOS_DIR"/{prometheus,alertmanager,loki,alloy,grafana}
ok "$DATOS_DIR"

info "Recolector"
install -d "$USER_UNIT_DIR"
install -m 0644 "$REPO_DIR/systemd/monitoreo-recolector.service" "$REPO_DIR/systemd/monitoreo-recolector.timer" "$USER_UNIT_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now monitoreo-recolector.timer >/dev/null
systemctl --user start monitoreo-recolector.service
ok "recolector"

info "Imágenes"
dc pull -q
ok "imágenes descargadas"

info "Arranque"
dc up -d --force-recreate --remove-orphans

fallos=0
wait_http http://127.0.0.1:9091/-/ready prometheus || fallos=1
wait_http http://127.0.0.1:9093/-/ready alertmanager || fallos=1
wait_http http://127.0.0.1:3100/ready loki 180 || fallos=1
wait_http http://127.0.0.1:12345/-/ready alloy || fallos=1
wait_http http://127.0.0.1:3000/api/health grafana 180 || fallos=1
wait_http http://127.0.0.1:9115/-/healthy blackbox || fallos=1
wait_http http://127.0.0.1:9882/metrics cadvisor || fallos=1
if $usar_postgres; then
  wait_http http://127.0.0.1:9187/metrics postgres-exporter || fallos=1
fi

echo
if ((fallos)); then
  warn "Hay componentes sin responder. Revisa: docker logs <contenedor> --tail 50"
else
  ok "Monitoreo instalado."
fi
echo "    Grafana: usuario admin, clave en $SECRETOS_DIR/grafana-admin"
echo "    Estado:  ./scripts/status.sh"
echo "    Prueba:  ./scripts/probar-alerta.sh"
