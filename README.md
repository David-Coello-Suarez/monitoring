# monitoreo-servidor

Monitoreo integral del servidor Linux Mint (`Server`, 192.168.100.59): hardware, sistema, servicios systemd del sistema y del usuario, contenedores Podman, apps, túnel de Cloudflare, PostgreSQL, logs y seguridad.

Todo corre **en el servidor**: recolecta, guarda historial y avisa por Telegram aunque la PC de escritorio esté apagada. La PC solo mira, por un túnel SSH.

```
Servidor (24/7)                                               PC (cuando esté encendida)
  node-exporter ─┐                                              acceso/conectar.ps1
  podman-exporter┤                                                │  ssh -L 13000 -L 19090
  postgres-exp. ─┼─> Prometheus ─> Alertmanager ─> Telegram       │  (cloudflared access ssh
  blackbox ──────┤        │                                       │   o LAN puerto 97)
  cloudflared ───┘        └──> Grafana 127.0.0.1:3000 <───────────┤
  journald ──> Alloy ──> Loki ──┘  (reglas LogQL → Alertmanager)  │
  Cockpit 127.0.0.1:9090 <────────────────────────────────────────┘
```

Ningún componente escucha fuera de `127.0.0.1`. No se abre ningún puerto nuevo.

## Ramas

Cada rama es el mismo monitoreo, orientado a una plataforma. Se elige al clonar con `git clone -b <rama>`.

| Rama | Plataforma | Despliegue |
|---|---|---|
| `podman` | Podman rootless (esta rama) | Quadlet + systemd de usuario |
| `docker` | Docker | Docker Compose |
| `kubernetes` | k3s de un nodo | Kustomize |

La configuración compartida (dashboards, reglas, Loki) se cambia en `podman` y se lleva a las otras ramas con `git cherry-pick`. No se hace merge entre ramas: cada una reemplaza archivos de las otras.

## Componentes

| Dónde | Componente | Qué vigila |
|---|---|---|
| Host (apt, root) | `prometheus-node-exporter` + colectores apt y smartmon | CPU, RAM, swap, disco, I/O, red, WiFi, temperatura, SMART, servicios systemd del sistema, paquetes pendientes, reinicio requerido |
| Host (apt, root) | Cockpit + cockpit-podman | Ver y reiniciar servicios y contenedores, logs, terminal |
| Usuario (timer) | `monitoreo-recolector` | Servicios systemd de usuario (Quadlet) y puertos en escucha |
| Quadlet rootless | Prometheus (30 días) | Métricas y reglas de alerta |
| Quadlet rootless | Alertmanager | Avisos a Telegram y latido externo opcional |
| Quadlet rootless | Loki (14 días) + Alloy | Journal completo del sistema y del usuario, contenedores, sshd, fail2ban, kernel |
| Quadlet rootless | blackbox | Apps por dentro (127.0.0.1:808x) y por fuera (dominios de Cloudflare), router y salida a internet |
| Quadlet rootless | podman-exporter | Estado, salud, reinicios, CPU, RAM y red por contenedor |
| Quadlet rootless | postgres-exporter | `postgres-demo` con un rol `monitoreo` (`pg_monitor`) |
| Quadlet rootless | Grafana | Dashboards: Resumen, Características del servidor, Node Exporter Full, Contenedores, PostgreSQL, Blackbox, Logs, Seguridad |

Todos los contenedores usan `Network=host` y escuchan solo en loopback, para alcanzar node-exporter, cloudflared y las apps sin exponer nada. Corren con `ReadOnly`, `DropCapability=ALL`, `NoNewPrivileges` e imágenes fijadas por digest.

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
| 9882 | podman-exporter |
| 12345 | Alloy |

## Instalación en el servidor

Antes de instalar, revisa [ANTES-DE-INSTALAR.md](ANTES-DE-INSTALAR.md): preparativos, revisiones, qué cambia en el servidor, riesgos y verificación.

Requisitos: Podman ≥ 4.4, sesión `systemd --user` (entra por `ssh`, no `sudo su`), linger activo y journal persistente.

```bash
git clone <repo> ~/monitoreo-servidor && cd ~/monitoreo-servidor
cp .env.example .env && nano .env          # TELEGRAM_CHAT_ID como mínimo
sudo ./scripts/install-host.sh             # una vez: paquetes del host, Cockpit, ACL del journal, fail2ban
./scripts/install.sh                       # sin sudo: pide el token de Telegram la primera vez
./scripts/probar-alerta.sh                 # debe llegar un mensaje a Telegram
./scripts/status.sh
```

`install.sh` es idempotente. Para actualizar: `git pull && ./scripts/install.sh`.

Secretos (fuera del repo, permisos 600, también cargados como `podman secret`):

- `~/.config/monitoreo/secretos/telegram-token`
- `~/.config/monitoreo/secretos/grafana-admin`: clave del usuario `admin` de Grafana
- `~/.config/monitoreo/secretos/pg-password`: clave del rol `monitoreo` en PostgreSQL

Para cambiar el token de Telegram: borra su archivo y vuelve a ejecutar `install.sh`.

### Telegram

1. Habla con `@BotFather`, crea el bot y guarda el token.
2. Escríbele cualquier mensaje al bot (o agrégalo a un grupo).
3. Abre `https://api.telegram.org/bot<token>/getUpdates` y copia `chat.id` a `TELEGRAM_CHAT_ID`.

Severidades: `critical` y `warning` suenan; `info` y el `Watchdog` diario llegan en silencio. El `Watchdog` es el "sigo vivo": si un día no llega, el monitoreo está caído.

Para cubrir el caso en que el servidor pierde internet entero, define `HEALTHCHECKS_URL` (por ejemplo, healthchecks.io con periodo de 5 min). Ese servicio avisa cuando **deja** de recibir el latido.

## Acceso desde la PC

1. `winget install --id Cloudflare.cloudflared`
2. Copia los bloques de `acceso/ssh_config.ejemplo` a `%USERPROFILE%\.ssh\config`.
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
| Ataques web (por app: krivot, minga, solarlink) | fuerza bruta en el login (por IP y distribuida), escaneo de rutas, ráfaga de errores 4xx, ráfaga de peticiones. La API de minga (`/api/*`) no está cubierta: Caddy no la registra |
| Kernel | OOM kill, errores de disco |
| Monitoreo | objetivo caído, recolector detenido, notificaciones fallidas, Watchdog |

## Puntos a validar en el servidor

- **Puerto de métricas de cloudflared.** Sin `metrics:` fijo en `/etc/cloudflared/config.yml`, cloudflared elige otro puerto al reiniciar y Prometheus pierde el túnel. `install-host.sh` lo revisa.
- **fail2ban y el puerto 97.** La jail `sshd` por defecto protege el 22. Si sshd escucha en el 97, define `port = 97` en `/etc/fail2ban/jail.local`. El SSH que entra por cloudflared llega desde `127.0.0.1` y fail2ban lo ignora: protégelo con una política de Cloudflare Access.
- **Red por WiFi USB.** Es el punto más frágil: si cae, caen las apps, el túnel y los avisos. Conecta el cable (`eno1`) si es posible.
- **podman-exporter v1.21.2** se eligió antes de la v2.0.0 por compatibilidad con Podman 4.9. Si no entrega métricas, revisa `journalctl --user -u mon-podman-exporter`.

## GitOps con orches

[orches](https://github.com/orches-team/orches) aplica en el servidor, cada 2 minutos, las unidades Quadlet y systemd que estén en la **raíz** de la rama `podman`, al estilo de Argo CD pero sin Kubernetes. Añadir, modificar o borrar un `.container` en la raíz y hacer push basta para que el servidor lo cree, lo reinicie o lo elimine.

- `orches.container` es el propio orches. `prueba-orches.container` es un `whoami` de prueba en `127.0.0.1:18080`.
- Solo gestiona las unidades de la raíz. El monitoreo (`quadlet/mon-*`) sigue instalándose con `install.sh`, porque necesita configuración generada desde `.env` y secretos.
- No pongas en la raíz una unidad con el nombre de una que ya exista en el servidor: orches la sobrescribiría.

Puesta en marcha (una vez, con tu usuario):

```bash
mkdir -p ~/.config/orches ~/.config/containers/systemd
podman run --rm -it --userns=keep-id --pid=host \
  --mount type=bind,source=/run/user/$(id -u)/systemd,destination=/run/user/$(id -u)/systemd \
  -v ~/.config/orches:/var/lib/orches \
  -v ~/.config/containers/systemd:/etc/containers/systemd \
  --env XDG_RUNTIME_DIR=/run/user/$(id -u) \
  ghcr.io/orches-team/orches:0.1.0 init https://github.com/David-Coello-Suarez/monitoring.git
```

Estado y sincronización manual: `podman exec systemd-orches orches status` y `podman exec systemd-orches orches sync`. Para quitarlo: `podman exec systemd-orches orches prune`.

## Desinstalar

```bash
./scripts/uninstall.sh                # conserva datos y configuración
./scripts/uninstall.sh --purge-datos  # borra volúmenes y ~/.config/monitoreo
```

Los paquetes del host (node-exporter, Cockpit) se quitan con `apt`.
