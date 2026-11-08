# monitoreo-servidor

Monitoreo del servidor Linux Mint 22 (Ubuntu 24.04 noble, Podman 4.9.3, usuario `david_coello` uid 1000, linger activo). Se edita en la PC Windows (`C:\Users\ELITEBOOK\Desktop\Entorno\monitoreo`) y se instala en el servidor con `git clone` + `scripts/install.sh`.

## Arquitectura

- Host (root, apt): `prometheus-node-exporter` en `127.0.0.1:9100` con colectores systemd, wifi y textfile (`/var/lib/prometheus/node-exporter`), Cockpit en `127.0.0.1:9090`. Lo instala `scripts/install-host.sh`.
- Usuario: Quadlet rootless en `~/.config/containers/systemd/mon-*.container`, todos con `Network=host` y escuchando solo en loopback. Prometheus usa 9091 porque Cockpit ocupa 9090.
- `monitoreo-recolector.timer` (usuario) escribe `usuario.prom` en el directorio textfile: servicios `systemctl --user`, puertos de `ss` y `monitoreo_servidor_info` (modelo de CPU, IP de la LAN, puerta de enlace e interfaz, que node-exporter no publica). El directorio tiene ACL de escritura para el usuario.
- Alloy lee `/var/log/journal` gracias a una ACL que pone `install-host.sh`. No se toca el grupo `systemd-journal` para no reiniciar `user@1000.service`, que tumbaría las apps.
- Alloy corre con `UserNS=keep-id:uid=473,gid=473` (uid de alloy en la imagen) y podman-exporter con `HOME=/tmp`: sin eso no arrancan en Podman 4.9.
- El recolector ignora las unidades transitorias de healthcheck de Podman (`<64 hex>.service`); la salud de contenedores la mide podman-exporter.
- Secretos: archivos 600 en `~/.config/monitoreo/secretos/` y `podman secret` (`mon-telegram-token`, `mon-grafana-admin`, `mon-pg-password`).

## Archivos

- `scripts/generar-config.sh`: copia la configuración a `~/.config/monitoreo` y genera `objetivos/*.yml`, `reglas/especificas.yml` y `alertmanager.yml` desde `.env`. Se prueba en Windows con `MONITOREO_ENV` y `MONITOREO_CONF_DIR`.
- Grupo `ataques-web` de `loki/reglas/seguridad.yml`: una tanda de 5 reglas por app, desde los logs de Traefik (krivot) y nginx (minga, solarlink). Las SPA responden 200 a rutas inexistentes, así que los escaneos se detectan por la ruta y no por contar 404. Se excluyen IP privadas y el User-Agent `Blackbox` (las sondas externas salen con la IP pública del servidor).
- `prometheus/reglas/servidor.yml`: reglas fijas. `loki/reglas/seguridad.yml`: reglas LogQL; las `expr` van como bloque `|` (un `: ` en línea rompe el YAML).
- `grafana/dashboards/`: `resumen`, `caracteristicas`, `contenedores`, `logs`, `seguridad` (propios) y `servidor-node-exporter` (1860), `postgresql` (9628), `blackbox` (13659) de grafana.com, con el datasource fijado a uid `prometheus`.

## Validar antes de subir

Con Podman local, sobre una configuración renderizada con `generar-config.sh`:

- `promtool check config --syntax-only` y `promtool check rules`
- `amtool check-config`
- `loki -verify-config`, y levantar Loki para confirmar que el ruler carga las reglas
- `alloy validate`
- `blackbox_exporter --config.check`
- `shellcheck -x -S warning scripts/*.sh`

## Servidor

Apps: minga `127.0.0.1:8081` (otsmart.circutbytes.tech), krivot `8082`, solarlink `8083`. Túnel `cloudflared-tunel.service` con métricas en `127.0.0.1:20250`. SSH en el puerto 97 (también `ssh.circutbytes.tech`). `postgres` (global) en `192.168.100.59:5432` y loopback.
