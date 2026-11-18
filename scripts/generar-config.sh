#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

CONF_DIR="${MONITOREO_CONF_DIR:-$CONF_DIR}"
usar_postgres="${USAR_POSTGRES:-false}"
load_env
[[ -n "${TELEGRAM_CHAT_ID:-}" ]] || die "TELEGRAM_CHAT_ID está vacío en .env"
install -d "$CONF_DIR"

info "Configuración en $CONF_DIR"
for d in prometheus alertmanager loki alloy blackbox grafana; do
  rm -rf "${CONF_DIR:?}/$d"
  cp -r "$REPO_DIR/$d" "$CONF_DIR/$d"
done
install -d "$CONF_DIR/bin" "$CONF_DIR/prometheus/objetivos"
install -m 0755 "$REPO_DIR/scripts/recolector.sh" "$CONF_DIR/bin/recolector.sh"
sed -i "s/__SERVIDOR__/$SERVIDOR_NOMBRE/; s/__CLOUDFLARED_PUERTO__/$CLOUDFLARED_METRICAS_PUERTO/" "$CONF_DIR/prometheus/prometheus.yml"
sed -i "s/__SERVIDOR__/$SERVIDOR_NOMBRE/" "$CONF_DIR/loki/loki.yml"
if [[ -n "${GRAFANA_URL_PUBLICA:-}" ]]; then
  [[ "$GRAFANA_URL_PUBLICA" =~ ^https://[A-Za-z0-9.-]+/?$ ]] || die "GRAFANA_URL_PUBLICA debe ser https://dominio"
  printf 'GF_SERVER_ROOT_URL=%s/\n' "${GRAFANA_URL_PUBLICA%/}" >>"$CONF_DIR/grafana/grafana.env"
fi

{
  for app in "${APPS[@]}"; do
    IFS='|' read -r nombre interna externa <<<"$app"
    printf -- '- targets: ["%s"]\n  labels: {app: "%s", tipo: interna}\n' "$interna" "$nombre"
    [[ -z "$externa" ]] || printf -- '- targets: ["%s"]\n  labels: {app: "%s", tipo: externa}\n' "$externa" "$nombre"
  done
} >"$CONF_DIR/prometheus/objetivos/apps.yml"

cat >"$CONF_DIR/prometheus/objetivos/red.yml" <<EOF
- targets: ["$GATEWAY_LAN"]
  labels: {destino: gateway}
- targets: ["$DESTINO_INTERNET"]
  labels: {destino: internet}
EOF

if $usar_postgres; then
  printf -- '- targets: ["127.0.0.1:9187"]\n  labels: {contenedor: "%s"}\n' "$POSTGRES_CONTENEDOR" >"$CONF_DIR/prometheus/objetivos/postgres.yml"
  cat >"$CONF_DIR/postgres-exporter.env" <<EOF
DATA_SOURCE_URI=127.0.0.1:$POSTGRES_PUERTO/${POSTGRES_BASE:-postgres}?sslmode=disable
DATA_SOURCE_USER=monitoreo
DATA_SOURCE_PASS_FILE=/run/secrets/pg-password
EOF
else
  echo "[]" >"$CONF_DIR/prometheus/objetivos/postgres.yml"
fi

re_sistema="$(join_regex "${UNIDADES_SISTEMA_CRITICAS[@]}")"
re_usuario="$(join_regex "${UNIDADES_USUARIO_CRITICAS[@]}")"
re_puertos="$(join_regex "${PUERTOS_PUBLICOS_PERMITIDOS[@]}")"
re_excluidos="${CONTENEDORES_EXCLUIDOS:-^$}"
{
  cat <<EOF
groups:
  - name: especificas
    rules:
      - alert: ServicioSistemaCaido
        expr: node_systemd_unit_state{name=~\`$re_sistema\`,state="active"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "El servicio del sistema {{ \$labels.name }} no está activo"
      - alert: ServicioUsuarioCaido
        expr: monitoreo_unidad_usuario{unit=~\`$re_usuario\`,active!="active"} == 1
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "El servicio {{ \$labels.unit }} está {{ \$labels.active }}"
      - alert: PuertoPublicoNoPermitido
        expr: monitoreo_puerto_escucha{direccion=~\`0\.0\.0\.0|\[::\]|\*\`,puerto!~\`$re_puertos\`} == 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Puerto {{ \$labels.puerto }} abierto en todas las interfaces ({{ \$labels.direccion }})"
      - alert: ContenedorDetenido
        expr: podman_container_state{name!~\`$re_excluidos\`} != 2
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "El contenedor {{ \$labels.name }} no está en ejecución"
      - alert: InterfazRedCaida
        expr: node_network_up{device="$INTERFAZ_RED"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "La interfaz de red $INTERFAZ_RED está caída"
EOF
  for unidad in "${UNIDADES_SISTEMA_CRITICAS[@]}"; do
    cat <<EOF
      - alert: ServicioSistemaAusente
        expr: absent(node_systemd_unit_state{name="$unidad",state="active"})
        for: 5m
        labels:
          severity: warning
          unidad: "$unidad"
        annotations:
          summary: "No hay datos del servicio $unidad (¿no existe o se renombró?)"
EOF
  done
  for unidad in "${UNIDADES_USUARIO_CRITICAS[@]}"; do
    cat <<EOF
      - alert: ServicioUsuarioAusente
        expr: absent(monitoreo_unidad_usuario{unit="$unidad"})
        for: 5m
        labels:
          severity: critical
          unidad: "$unidad"
        annotations:
          summary: "El servicio de usuario $unidad no existe o no está cargado"
EOF
  done
} >"$CONF_DIR/prometheus/reglas/especificas.yml"

latido_ruta="" latido_receptor=""
if [[ -n "${HEALTHCHECKS_URL:-}" ]]; then
  latido_ruta=$'    - matchers: [alertname="Watchdog"]\n      receiver: latido\n      group_wait: 0s\n      group_interval: 1m\n      repeat_interval: 5m\n      continue: true'
  latido_receptor=$'  - name: latido\n    webhook_configs:\n      - url: "'"$HEALTHCHECKS_URL"$'"\n        send_resolved: false'
fi
cat >"$CONF_DIR/alertmanager/alertmanager.yml" <<EOF
global:
  resolve_timeout: 5m

templates:
  - /etc/alertmanager/plantillas/*.tmpl

route:
  receiver: telegram
  group_by: [alertname, app, name, unit, unidad, device, mountpoint]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
$latido_ruta
    - matchers: [alertname="Watchdog"]
      receiver: telegram-silencioso
      repeat_interval: 24h
    - matchers: [severity="info"]
      receiver: telegram-silencioso
      repeat_interval: 24h

inhibit_rules:
  - source_matchers: [alertname=~"GatewayInaccesible|SinInternet|InterfazRedCaida"]
    target_matchers: [alertname=~"AppExternaCaida|TunelSinConexiones|TunelDegradado|NotificacionesFallidas"]
  - source_matchers: [alertname="ServidorSinMetricas"]
    target_matchers: [alertname=~"ServicioSistemaAusente|RecolectorDetenido"]
  - source_matchers: [alertname="AppInternaCaida"]
    target_matchers: [alertname=~"AppExternaCaida|AppLenta"]
    equal: [app]
  - source_matchers: [alertname="ContenedorDetenido"]
    target_matchers: [alertname=~"ContenedorUnhealthy|ContenedorReiniciando"]
    equal: [name]

receivers:
  - name: telegram
    telegram_configs:
      - bot_token_file: /run/secrets/telegram-token
        chat_id: $TELEGRAM_CHAT_ID
        parse_mode: HTML
        send_resolved: true
        message: '{{ template "telegram.mensaje" . }}'
  - name: telegram-silencioso
    telegram_configs:
      - bot_token_file: /run/secrets/telegram-token
        chat_id: $TELEGRAM_CHAT_ID
        parse_mode: HTML
        send_resolved: false
        disable_notifications: true
        message: '{{ template "telegram.mensaje" . }}'
$latido_receptor
EOF
chmod 0644 "$CONF_DIR/alertmanager/alertmanager.yml"
ok "configuración generada"

