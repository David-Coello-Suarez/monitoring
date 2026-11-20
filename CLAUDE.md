# monitoreo-servidor

Monitoreo del servidor Linux Mint 22 (Ubuntu 24.04 noble, Podman 4.9.3, usuario `david_coello` uid 1000, linger activo). Se edita en la PC Windows (`C:\Users\ELITEBOOK\Desktop\Entorno\monitoreo`) y se instala en el servidor con `git clone` + `scripts/install.sh`.

## Ramas

- `podman` (esta, rama por defecto), `docker` (Compose) y `kubernetes` (Kustomize sobre k3s de un nodo). Son ramas permanentes con los mismos componentes, alertas y dashboards.
- La configuración compartida se cambia en `podman` y se lleva a las otras con `git cherry-pick`. Nunca se hace merge entre ramas: cada una reemplaza archivos de las otras.

## Arquitectura

- Host (root, apt): `prometheus-node-exporter` en `127.0.0.1:9100` con colectores systemd, wifi y textfile (`/var/lib/prometheus/node-exporter`), Cockpit en `127.0.0.1:9090`. Lo instala `scripts/install-host.sh`.
- Usuario: Quadlet rootless en `~/.config/containers/systemd/mon-*.container`, todos con `Network=host` y escuchando solo en loopback. Prometheus usa 9091 porque Cockpit ocupa 9090.
- `monitoreo-recolector.timer` (usuario) escribe `usuario.prom` en el directorio textfile: servicios `systemctl --user`, puertos de `ss` y `monitoreo_servidor_info` (modelo de CPU, IP de la LAN, puerta de enlace e interfaz, que node-exporter no publica). El directorio tiene ACL de escritura para el usuario.
- Alloy lee `/var/log/journal` gracias a una ACL que pone `install-host.sh`. No se toca el grupo `systemd-journal` para no reiniciar `user@1000.service`, que tumbaría las apps.
- Alloy corre con `UserNS=keep-id:uid=473,gid=473` (uid de alloy en la imagen) y podman-exporter con `HOME=/tmp`: sin eso no arrancan en Podman 4.9.
- El recolector ignora las unidades transitorias de healthcheck de Podman (`<64 hex>.service`); la salud de contenedores la mide podman-exporter.
- El recolector vigila podman-exporter: publica `monitoreo_contenedores_podman` (`podman ps -a`) y `monitoreo_podman_exporter_ultimo_reinicio_segundos`, y reinicia `mon-podman-exporter` si su número de `podman_container_info` difiere del de Podman en dos pasadas seguidas (pausa de 10 min entre reinicios; estado en `~/.local/state/monitoreo/`). Motivo: la v1.21.2 con Podman 4.9 puede quedarse con la lista vacía si arranca antes que los contenedores, sin error y con `podman_scrape_collector_success` a 1. `PodmanExporterIncompleto` avisa si la diferencia dura 10 min.
- Secretos: archivos 600 en `~/.config/monitoreo/secretos/` y `podman secret` (`mon-telegram-token`, `mon-grafana-admin`, `mon-pg-password`).

## Archivos

- `scripts/generar-config.sh`: copia la configuración a `~/.config/monitoreo` y genera `objetivos/*.yml`, `reglas/especificas.yml` y `alertmanager.yml` desde `.env`. Se prueba en Windows con `MONITOREO_ENV` y `MONITOREO_CONF_DIR`. `APPS` admite un 4.º campo, el módulo de blackbox (por defecto `http_app`), que pasa como etiqueta `modulo` a `__param_module`; `sotenet-api` usa `http_api_401` (espera 401 en `/api/v1/me`). `SOTENET_METRICAS_PUERTO` genera `objetivos/sotenet.yml` (job `sotenet`, `[]` si está vacío). Alertmanager agrupa también por `service`.
- Grupo `ataques-web` de `loki/reglas/seguridad.yml`: una tanda de reglas por app, desde los logs de Traefik (krivot y sotenet) y nginx (minga). Sotenet lee `{contenedor="sotenet-traefik"}` con `| json` y toma la IP de `request_Cf_Connecting_Ip` (cloudflared → Traefik; `ClientHost` no es fiable), filtra el login por `/v1/auth/login` y añade `WebRafagaLimiteTasa` (429 por IP). Las SPA responden 200 a rutas inexistentes, así que los escaneos se detectan por la ruta y no por contar 404. Se excluyen IP privadas y el User-Agent `Blackbox` (las sondas externas salen con la IP pública del servidor).
- Grupo `sotenet-backend` de `loki/reglas/seguridad.yml`: logs JSON de pino en `{contenedor="sotenet-backend"}` (`level` ≥ 50 errores, ≥ 60 fatal, `res_statusCode` 401/429 en `req_url` `/v1/auth/*`).
- `prometheus/reglas/sotenet.yml`: métricas de Traefik de Sotenet (`up{job="sotenet"}`, `traefik_service_server_up`, `traefik_service_requests_total`, `traefik_service_request_duration_seconds_bucket` de `backend@…`/`frontend@…`). `ObjetivoCaido` excluye el job `sotenet` porque lo cubre `SotenetTraefikCaido`.
- `trafico.json` (uid `mon-trafico`): tráfico entrante por app desde los logs de acceso en Loki (Traefik `entryPointName="web"` para krivot, `sotenet-traefik` para sotenet, nginx para minga) más el total de cloudflared. Variables `app` y `origen` (`no` = solo externo: sin Blackbox, IP privadas ni loopback). Las métricas Prometheus de Traefik (`10.90.3.2:8082`, red interna `krivot-monitor`) no son alcanzables desde Prometheus con `Network=host`. Las llamadas a la API de minga van por `minga-caddy`, que no registra accesos, así que no aparecen.
- `prometheus/reglas/servidor.yml`: reglas fijas. `loki/reglas/seguridad.yml`: reglas LogQL; las `expr` van como bloque `|` (un `: ` en línea rompe el YAML).
- `grafana/dashboards/`: `resumen`, `caracteristicas`, `contenedores`, `logs`, `seguridad`, `trafico`, `sotenet` (propios; `sotenet` con métricas de Traefik, logs de pino del backend y access log) y `servidor-node-exporter` (1860), `postgresql` (9628), `blackbox` (13659) de grafana.com, con el datasource fijado a uid `prometheus`.

## Validar antes de subir

Con Podman local, sobre una configuración renderizada con `generar-config.sh`:

- `promtool check config --syntax-only` y `promtool check rules`
- `amtool check-config`
- `loki -verify-config`, y levantar Loki para confirmar que el ruler carga las reglas
- `alloy validate`
- `blackbox_exporter --config.check`
- `shellcheck -x -S warning scripts/*.sh`

## Servidor

Apps: minga `127.0.0.1:8081` (otsmart.circutbytes.tech), krivot `8082`, sotenet `8083` a través de su Traefik (preprod.sotenet.com.ec; métricas de Traefik en `127.0.0.1:9102`; unidades `sotenet-traefik`, `sotenet-backend`, `sotenet-frontend` y el oneshot `sotenet-migrate`; deploy en `github.com/sotenet/deploy`). Túnel `cloudflared-tunel.service` con métricas en `127.0.0.1:20250`. SSH en el puerto 97 (también `ssh.circutbytes.tech`). `postgres` (global) en `192.168.100.59:5432` y loopback.

## Pendiente

- Cherry-pick de la integración de Sotenet a `docker` y `kubernetes`, adaptando en cada rama el job de Prometheus, `generar-config.sh` y el `.env`.
- Recomendaciones de la auditoría, sin implementar: límites de recursos en los contenedores `mon-*`, Loki sin autenticación (`auth_enabled: false`), `--web.enable-lifecycle` en Prometheus y el montaje de `podman.sock` en podman-exporter.
