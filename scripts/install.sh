#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

SERVICIOS=(mon-prometheus mon-alertmanager mon-loki mon-alloy mon-grafana mon-blackbox mon-podman-exporter)
SECRETOS_DIR="$CONF_DIR/secretos"

require_non_root
require_cmd podman systemctl curl ss sed
require_user_systemd
require_podman
load_env

[[ -n "${TELEGRAM_CHAT_ID:-}" ]] || die "TELEGRAM_CHAT_ID está vacío en .env"
[[ -d /var/lib/prometheus/node-exporter && -w /var/lib/prometheus/node-exporter ]] ||
  die "falta el lado host. Ejecuta primero: sudo ./scripts/install-host.sh"

usar_postgres=false
if [[ -n "${POSTGRES_CONTENEDOR:-}" ]]; then
  if podman container exists "$POSTGRES_CONTENEDOR"; then
    usar_postgres=true
    SERVICIOS+=(mon-postgres-exporter)
  else
    warn "no existe el contenedor $POSTGRES_CONTENEDOR: no instalo postgres-exporter"
  fi
fi

podman_secret() {
  local nombre="$1" archivo="$2"
  podman secret rm "$nombre" >/dev/null 2>&1 || true
  podman secret create "$nombre" "$archivo" >/dev/null
}

generar_clave() {
  # Lee una cantidad finita de /dev/urandom: con `tr </dev/urandom | head`, tr
  # muere por SIGPIPE (141) y pipefail aborta el script sin mensaje.
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
podman_secret mon-telegram-token "$SECRETOS_DIR/telegram-token"
podman_secret mon-grafana-admin "$SECRETOS_DIR/grafana-admin"
ok "telegram y grafana"

if $usar_postgres; then
  [[ -s "$SECRETOS_DIR/pg-password" ]] || (umask 077 && generar_clave 32 >"$SECRETOS_DIR/pg-password")
  podman_secret mon-pg-password "$SECRETOS_DIR/pg-password"
  {
    printf "\\set clave '%s'\n" "$(cat "$SECRETOS_DIR/pg-password")"
    cat <<'SQL'
SELECT 'CREATE ROLE monitoreo LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitoreo')\gexec
ALTER ROLE monitoreo WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'clave';
GRANT pg_monitor TO monitoreo;
SQL
  } | podman exec -i "$POSTGRES_CONTENEDOR" sh -c 'psql -q -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"' >/dev/null
  ok "rol monitoreo (pg_monitor) en $POSTGRES_CONTENEDOR"
fi

info "Configuración en $CONF_DIR"
USAR_POSTGRES="$usar_postgres" "$REPO_DIR/scripts/generar-config.sh"

info "Unidades"
install -d "$QUADLET_DIR" "$USER_UNIT_DIR"
for s in "${SERVICIOS[@]}"; do
  install -m 0644 "$REPO_DIR/quadlet/$s.container" "$QUADLET_DIR/$s.container"
done
$usar_postgres || rm -f "$QUADLET_DIR/mon-postgres-exporter.container"
install -m 0644 "$REPO_DIR/systemd/monitoreo-recolector.service" "$REPO_DIR/systemd/monitoreo-recolector.timer" "$USER_UNIT_DIR/"
systemctl --user enable --now podman.socket >/dev/null
systemctl --user daemon-reload
systemctl --user enable --now monitoreo-recolector.timer >/dev/null
systemctl --user start monitoreo-recolector.service
ok "quadlets y recolector"

info "Imágenes"
for s in "${SERVICIOS[@]}"; do
  imagen="$(sed -n 's/^Image=//p' "$QUADLET_DIR/$s.container")"
  podman image exists "$imagen" || podman pull -q "$imagen" >/dev/null
done
ok "imágenes descargadas"

info "Arranque"
for s in "${SERVICIOS[@]}"; do
  systemctl --user restart "$s.service"
done

fallos=0
wait_http http://127.0.0.1:9091/-/ready prometheus || fallos=1
wait_http http://127.0.0.1:9093/-/ready alertmanager || fallos=1
wait_http http://127.0.0.1:3100/ready loki 180 || fallos=1
wait_http http://127.0.0.1:12345/-/ready alloy || fallos=1
wait_http http://127.0.0.1:3000/api/health grafana 180 || fallos=1
wait_http http://127.0.0.1:9115/-/healthy blackbox || fallos=1
wait_http http://127.0.0.1:9882/metrics podman-exporter || fallos=1
if $usar_postgres; then
  wait_http http://127.0.0.1:9187/metrics postgres-exporter || fallos=1
fi

echo
if ((fallos)); then
  warn "Hay componentes sin responder. Revisa: journalctl --user -u <servicio> -n 50"
else
  ok "Monitoreo instalado."
fi
echo "    Grafana: usuario admin, clave en $SECRETOS_DIR/grafana-admin"
echo "    Estado:  ./scripts/status.sh"
echo "    Prueba:  ./scripts/probar-alerta.sh"
