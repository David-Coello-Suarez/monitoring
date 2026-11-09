# monitoreo-servidor (Docker)

Monitoreo integral de un servidor Linux con Docker: hardware, sistema, servicios systemd, contenedores Docker, apps, túnel de Cloudflare, PostgreSQL, logs y seguridad.

Todo corre **en el servidor**: recolecta, guarda historial y avisa por Telegram aunque la PC de escritorio esté apagada. La PC solo mira, por un túnel SSH.

```
Servidor (24/7)                                               PC (cuando esté encendida)
  node-exporter ─┐                                              acceso/conectar.ps1
  cAdvisor ──────┤                                                │  ssh -L 13000 -L 19090
  postgres-exp. ─┼─> Prometheus ─> Alertmanager ─> Telegram       │  (cloudflared access ssh
  blackbox ──────┤        │                                       │   o LAN)
  cloudflared ───┘        └──> Grafana 127.0.0.1:3000 <───────────┤
  journald ──> Alloy ──> Loki ──┘  (reglas LogQL → Alertmanager)  │
  Cockpit 127.0.0.1:9090 <────────────────────────────────────────┘
```

Ningún componente escucha fuera de `127.0.0.1`. No se abre ningún puerto nuevo.

## Ramas

Cada rama es el mismo monitoreo, orientado a una plataforma. Se elige al clonar con `git clone -b <rama>`.

| Rama | Plataforma | Despliegue |
|---|---|---|
| `podman` | Podman rootless | Quadlet + systemd de usuario |
| `docker` | Docker (esta rama) | Docker Compose |
| `kubernetes` | k3s de un nodo | Kustomize |

La configuración compartida (dashboards, reglas, Loki) se cambia en `podman` y se lleva a las otras ramas con `git cherry-pick`. No se hace merge entre ramas: cada una reemplaza archivos de las otras.

## Componentes

| Dónde | Componente | Qué vigila |
|---|---|---|
| Host (apt, root) | `prometheus-node-exporter` + colectores apt y smartmon | CPU, RAM, swap, disco, I/O, red, WiFi, temperatura, SMART, servicios systemd del sistema, paquetes pendientes, reinicio requerido |
| Host (apt, root) | Cockpit | Servicios, logs y terminal (los contenedores se gestionan con `docker` desde su terminal) |
| Usuario (timer) | `monitoreo-recolector` | Estado, salud y arranques de cada contenedor, versiones de Docker, servicios systemd de usuario y puertos en escucha |
| Compose | Prometheus (30 días) | Métricas y reglas de alerta |
| Compose | Alertmanager | Avisos a Telegram y latido externo opcional |
| Compose | Loki (14 días) + Alloy | Journal completo del sistema y del usuario, contenedores, sshd, fail2ban, kernel |
| Compose | blackbox | Apps por dentro (127.0.0.1:808x) y por fuera (dominios de Cloudflare), router y salida a internet |
| Compose | cAdvisor | CPU, RAM y red por contenedor |
| Compose (perfil `postgres`) | postgres-exporter | Contenedor PostgreSQL con un rol `monitoreo` (`pg_monitor`) |
| Compose | Grafana | Dashboards: Resumen, Características del servidor, Node Exporter Full, Contenedores, PostgreSQL, Blackbox, Logs, Seguridad |

Todos los contenedores usan `network_mode: host` y escuchan solo en loopback, para alcanzar node-exporter, cloudflared y las apps sin exponer nada. Corren con tu uid, `read_only`, `cap_drop: ALL`, `no-new-privileges` e imágenes fijadas por digest. La excepción es cAdvisor: necesita `privileged` y montajes del host para leer los cgroups de todos los contenedores.

| Puerto (127.0.0.1) | Servicio |
|---|---|
| 3000 | Grafana |
| 3100 / 9095 | Loki |
| 9090 | Cockpit |
| 9091 | Prometheus |
| 9093 | Alertmanager |
| 9100 | node-exporter |
| 9115 | blackbox |
| 9187 | postgres-exporter |
| 9882 | cAdvisor |
| 12345 | Alloy |

## Instalación en el servidor

Antes de instalar, revisa [ANTES-DE-INSTALAR.md](ANTES-DE-INSTALAR.md): preparativos, revisiones, qué cambia en el servidor, riesgos y verificación.

Requisitos: Docker Engine con el plugin Compose v2, tu usuario en el grupo `docker`, sesión `systemd --user` (entra por `ssh`, no `sudo su`), linger activo, journal persistente y Docker con `"log-driver": "journald"`.

```bash
git clone -b docker <repo> ~/monitoreo-servidor && cd ~/monitoreo-servidor
cp .env.example .env && nano .env          # TELEGRAM_CHAT_ID como mínimo
sudo ./scripts/install-host.sh             # una vez: paquetes del host, Cockpit, ACL del journal, fail2ban
./scripts/install.sh                       # sin sudo: pide el token de Telegram la primera vez
./scripts/probar-alerta.sh                 # debe llegar un mensaje a Telegram
./scripts/status.sh
```

`install.sh` es idempotente. Para actualizar: `git pull && ./scripts/install.sh`.

Secretos (fuera del repo, permisos 600). Compose los monta como archivos en `/run/secrets`:

- `~/.config/monitoreo/secretos/telegram-token`
- `~/.config/monitoreo/secretos/grafana-admin`: clave del usuario `admin` de Grafana
- `~/.config/monitoreo/secretos/pg-password`: clave del rol `monitoreo` en PostgreSQL

Para cambiar el token de Telegram: borra su archivo y vuelve a ejecutar `install.sh`.

Datos persistentes en `~/.local/share/monitoreo/<servicio>`. El proyecto de Compose se llama `monitoreo`; para manejarlo a mano usa las mismas opciones que `scripts/lib.bash` (`dc`).

### Telegram

1. Habla con `@BotFather`, crea el bot y guarda el token.
2. Escríbele cualquier mensaje al bot (o agrégalo a un grupo).
3. Abre `https://api.telegram.org/bot<token>/getUpdates` y copia `chat.id` a `TELEGRAM_CHAT_ID`.

Severidades: `critical` y `warning` suenan; `info` y el `Watchdog` diario llegan en silencio. El `Watchdog` es el "sigo vivo": si un día no llega, el monitoreo está caído.

Para cubrir el caso en que el servidor pierde internet entero, define `HEALTHCHECKS_URL` (por ejemplo, healthchecks.io con periodo de 5 min). Ese servicio avisa cuando **deja** de recibir el latido.

## Acceso desde la PC

1. `winget install --id Cloudflare.cloudflared`
2. Copia los bloques de `acceso/ssh_config.ejemplo` a `%USERPROFILE%\.ssh\config` y ajusta host, puerto y usuario.
3. `.\acceso\conectar.ps1` (desde fuera de casa, por Cloudflare) o `.\acceso\conectar.ps1 -Lan` (en la LAN).

Abre Grafana en `http://localhost:13000` y Cockpit en `http://localhost:19090`. Ctrl+C cierra el túnel.

## Alertas

Reglas en `prometheus/reglas/servidor.yml` (fijas), `prometheus/reglas/especificas.yml` (generada desde `.env`) y `loki/reglas/seguridad.yml` (LogQL).

| Grupo | Alertas |
|---|---|
| Host | sin métricas, CPU, memoria, swap, carga, disco bajo, disco lleno en 24 h, inodos, temperatura, SMART, reloj, reinicio, reinicio requerido, paquetes pendientes, servicio del sistema `failed` |
| Servicios críticos | servicio del sistema o de usuario caído o ausente (listas en `.env`) |
| Red | interfaz caída, señal WiFi débil, errores de red, router inaccesible, sin internet, adaptador WiFi que se desconecta |
| Túnel | sin conexiones, degradado, errores hacia las apps |
| Apps | caída interna, caída solo por Cloudflare, lentitud, certificado por vencer |
| Contenedores | detenido, unhealthy, reinicios en bucle, memoria cerca del límite |
| Seguridad | ráfaga de SSH fallidos, login root, login SSH (info), baneos de fail2ban, sudo con clave incorrecta, puerto abierto en todas las interfaces fuera de la lista permitida |
| Ataques web (por app) | fuerza bruta en el login (por IP y distribuida), escaneo de rutas, ráfaga de errores 4xx, ráfaga de peticiones. Las reglas vienen para los contenedores `traefik`, `minga-frontend` y `solarlink-frontend`; ajústalas en `loki/reglas/seguridad.yml` a los nombres de tus contenedores |
| Kernel | OOM kill, errores de disco |
| Monitoreo | objetivo caído, recolector detenido, notificaciones fallidas, Watchdog |

Las métricas de contenedores salen de dos fuentes: cAdvisor (CPU, RAM, red, límite de memoria) y el recolector (`monitoreo_contenedor_estado`, `monitoreo_contenedor_salud`, `monitoreo_contenedor_arranque_segundos`, `monitoreo_docker_info`), porque cAdvisor no publica estado ni healthcheck.

## Puntos a validar en el servidor

- **Driver de logs de Docker.** Sin `"log-driver": "journald"` en `/etc/docker/daemon.json`, los logs de tus apps no llegan a Loki y las reglas de ataques web no ven nada. `install-host.sh` lo revisa. Al cambiarlo, recrea tus contenedores.
- **Grupo `docker`.** Pertenecer a él equivale a tener acceso root en el host. El recolector lo necesita para leer el estado de los contenedores.
- **Puerto de métricas de cloudflared.** Sin `metrics:` fijo en `/etc/cloudflared/config.yml`, cloudflared elige otro puerto al reiniciar y Prometheus pierde el túnel. `install-host.sh` lo revisa.
- **fail2ban y el puerto de SSH.** La jail `sshd` por defecto protege el 22. Si sshd escucha en otro puerto, define `port = <puerto>` en `/etc/fail2ban/jail.local`. El SSH que entra por cloudflared llega desde `127.0.0.1` y fail2ban lo ignora: protégelo con una política de Cloudflare Access.

## Desinstalar

```bash
./scripts/uninstall.sh                # conserva datos y configuración
./scripts/uninstall.sh --purge-datos  # borra ~/.local/share/monitoreo y ~/.config/monitoreo
```

Los paquetes del host (node-exporter, Cockpit) se quitan con `apt`.
