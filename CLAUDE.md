# monitoreo-servidor (rama docker)

Monitoreo de un servidor Linux (Ubuntu 24.04 o derivado) con Docker Engine y Compose v2. Se edita en la PC Windows (`C:\Users\ELITEBOOK\Desktop\Entorno\monitoreo`) y se instala en el servidor con `git clone -b docker` + `scripts/install.sh`. Es un servidor distinto del que usa la rama `podman`.

## Ramas

- `podman` (rama por defecto), `docker` (esta, Compose) y `kubernetes` (Kustomize sobre k3s de un nodo). Son ramas permanentes con los mismos componentes, alertas y dashboards.
- La configuración compartida se cambia en `podman` y se lleva a las otras con `git cherry-pick`. Nunca se hace merge entre ramas: cada una reemplaza archivos de las otras.
- Archivos propios de esta rama: `compose.yml`, `scripts/*` (Docker en vez de Podman), las reglas de contenedores en `prometheus/reglas/servidor.yml` y `generar-config.sh`, y los dashboards `contenedores`, `resumen` y `caracteristicas`. Al hacer cherry-pick de `podman`, esos archivos dan conflicto: se resuelve conservando las métricas de Docker.

## Arquitectura

- Host (root, apt): `prometheus-node-exporter` en `127.0.0.1:9100` con colectores systemd, wifi y textfile (`/var/lib/prometheus/node-exporter`), Cockpit en `127.0.0.1:9090` sin plugin de contenedores. Lo instala `scripts/install-host.sh`, que además exige Docker, Compose v2 y el usuario en el grupo `docker`, y avisa si Docker no usa el driver de logs `journald`.
- `compose.yml`, proyecto `monitoreo`: todos con `network_mode: host` escuchando solo en loopback, `user: ${HOST_UID}:${HOST_GID}`, `read_only`, `cap_drop: ALL` y `logging: journald`. Prometheus usa 9091 porque Cockpit ocupa 9090. `postgres-exporter` va en el perfil `postgres`.
- Docker no tiene `:U` ni `keep-id`: por eso todo corre con el uid del usuario y los datos van en bind mounts de `~/.local/share/monitoreo/<servicio>`, que `install.sh` crea antes de arrancar (si los crea Docker, quedan de root). Con el mismo uid, los secretos 600 son legibles y Alloy usa la ACL del journal.
- Alloy guarda su estado en `/datos` y no en `/var/lib/alloy/data`: ese directorio es 0770 del uid 473 de la imagen.
- `compose.env` lo genera `generar-config.sh` en `~/.config/monitoreo` (uid, gid, rutas, perfil de Postgres). `lib.bash` define `dc` para llamar a Compose siempre con ese archivo. `.env` del repo no lo lee Compose.
- cAdvisor (`127.0.0.1:9882`, job `cadvisor`) es el único contenedor `privileged`. Da `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`, `container_spec_memory_limit_bytes` y `container_network_receive_bytes_total` con la etiqueta `name`. Lee containerd en `/run/containerd/containerd.sock` (ruta de Docker Engine).
- `monitoreo-recolector.timer` (usuario) escribe `usuario.prom`: servicios `systemctl --user`, puertos de `ss`, `monitoreo_servidor_info`, y desde `docker inspect` `monitoreo_contenedor_estado` (2 = corriendo), `monitoreo_contenedor_salud` (-1 sin healthcheck, 0 sano, 1 enfermo, 2 arrancando), `monitoreo_contenedor_arranque_segundos` y `monitoreo_docker_info`. Cada familia se imprime agrupada (formato de texto de Prometheus).
- `install.sh` comprueba con `systemd-run --user` que el gestor de usuario ve el grupo `docker`; si el usuario entró al grupo después de arrancar `user@.service`, el timer fallaría.
- Secretos: archivos 600 en `~/.config/monitoreo/secretos/`, montados por Compose en `/run/secrets/<nombre>`.

## Archivos

- `scripts/generar-config.sh`: copia la configuración a `~/.config/monitoreo`, genera `objetivos/*.yml`, `reglas/especificas.yml`, `alertmanager.yml` y `compose.env` desde `.env`. Se prueba en Windows con `MONITOREO_ENV` y `MONITOREO_CONF_DIR`.
- Grupo `ataques-web` de `loki/reglas/seguridad.yml`: se filtra por la etiqueta `contenedor` (nombre del contenedor en el journal). Viene con los nombres del servidor de la rama `podman`; en un servidor sin esos contenedores queda silencioso.
- `grafana/dashboards/`: `resumen`, `caracteristicas`, `contenedores`, `logs`, `seguridad` (propios) y `servidor-node-exporter` (1860), `postgresql` (9628), `blackbox` (13659) de grafana.com, con el datasource fijado a uid `prometheus`.

## Validar antes de subir

Con Podman local (`podman --connection podman-machine-default-root`) y un contenedor `docker:29-dind` desechable:

- `docker compose config -q` y arranque completo de `compose.yml` con `HOST_UID=1000`; en DinD usa un override con `logging: json-file` y `--containerd=/var/run/docker/containerd/containerd.sock` para cAdvisor
- `promtool check config --syntax-only`, `promtool check rules` y `promtool check metrics` sobre la salida del recolector
- `amtool check-config`, `loki -verify-config`, `alloy validate`, `blackbox_exporter --config.check`
- `shellcheck -x -S warning scripts/*.sh`
