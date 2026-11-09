# monitoreo-servidor (Kubernetes)

Monitoreo integral de un servidor Linux con k3s de un nodo: hardware, sistema, servicios systemd, pods y contenedores, apps, túnel de Cloudflare, PostgreSQL, logs y seguridad.

Todo corre **en el servidor**: recolecta, guarda historial y avisa por Telegram aunque la PC de escritorio esté apagada. La PC solo mira, por un túnel SSH.

```
Servidor (24/7)                                               PC (cuando esté encendida)
  node-exporter ──────┐                                         acceso/conectar.ps1
  kube-state-metrics ─┤                                           │  ssh -L 13000 -L 19090
  kubelet (cAdvisor) ─┼─> Prometheus ─> Alertmanager ─> Telegram  │  (cloudflared access ssh
  postgres-exp. ──────┤        │                                  │   o LAN)
  blackbox ───────────┤        └──> Grafana 127.0.0.1:3000 <──────┤
  cloudflared ────────┘                                           │
  journald + /var/log/pods ──> Alloy ──> Loki ──┘                 │
  Cockpit 127.0.0.1:9090 <────────────────────────────────────────┘
```

Ningún componente escucha fuera de `127.0.0.1`. No se abre ningún puerto nuevo ni se crea ningún Service.

## Ramas

Cada rama es el mismo monitoreo, orientado a una plataforma. Se elige al clonar con `git clone -b <rama>`.

| Rama | Plataforma | Despliegue |
|---|---|---|
| `podman` | Podman rootless | Quadlet + systemd de usuario |
| `docker` | Docker | Docker Compose |
| `kubernetes` | k3s de un nodo (esta rama) | Kustomize |

La configuración compartida (dashboards, reglas, Loki) se cambia en `podman` y se lleva a las otras ramas con `git cherry-pick`. No se hace merge entre ramas: cada una reemplaza archivos de las otras.

## Componentes

| Dónde | Componente | Qué vigila |
|---|---|---|
| Host (apt, root) | `prometheus-node-exporter` + colectores apt y smartmon | CPU, RAM, swap, disco, I/O, red, WiFi, temperatura, SMART, servicios systemd del sistema (incluido `k3s`), paquetes pendientes, reinicio requerido |
| Host (apt, root) | Cockpit | Servicios, logs y terminal (los pods se gestionan con `kubectl` desde su terminal) |
| Usuario (timer) | `monitoreo-recolector` | Servicios systemd de usuario, puertos en escucha y datos del equipo |
| StatefulSet | Prometheus (30 días) | Métricas, reglas de alerta y reglas de registro de contenedores |
| StatefulSet | Alertmanager | Avisos a Telegram y latido externo opcional |
| StatefulSet + DaemonSet | Loki (14 días) + Alloy | Journal completo del sistema y del usuario, logs de todos los pods, sshd, fail2ban, kernel |
| Deployment | blackbox | Apps por dentro (URL interna) y por fuera (dominios de Cloudflare), router y salida a internet |
| Deployment | kube-state-metrics | Estado, readiness y reinicios de cada contenedor; nodos, réplicas, Jobs y volúmenes |
| kubelet de k3s | cAdvisor | CPU, RAM y red por contenedor |
| Deployment (opcional) | postgres-exporter | PostgreSQL con un rol `monitoreo` (`pg_monitor`) |
| StatefulSet | Grafana | Dashboards: Resumen, Características del servidor, Node Exporter Full, Contenedores, PostgreSQL, Blackbox, Logs, Seguridad |

Todos los pods viven en el namespace `monitoreo`, usan `hostNetwork` y escuchan solo en loopback, para alcanzar node-exporter, cloudflared, el kubelet y las apps sin exponer nada. Corren sin root, con `readOnlyRootFilesystem`, sin capacidades, sin escalada de privilegios, con `requests` y `limits`, e imágenes fijadas por digest. Los datos van en PVC de la StorageClass `local-path` de k3s.

`hostNetwork` limita el despliegue a un nodo: es el destino de esta rama.

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
| 9882 / 9883 | kube-state-metrics (métricas / telemetría propia) |
| 10250 | kubelet de k3s (ya existe; lo abre k3s) |
| 12345 | Alloy |

## Instalación en el servidor

Antes de instalar, revisa [ANTES-DE-INSTALAR.md](ANTES-DE-INSTALAR.md): preparativos, revisiones, qué cambia en el servidor, riesgos y verificación.

Requisitos: k3s activo con la StorageClass `local-path`, sesión `systemd --user` (entra por `ssh`, no `sudo su`), linger activo y journal persistente.

```bash
git clone -b kubernetes <repo> ~/monitoreo-servidor && cd ~/monitoreo-servidor
cp .env.example .env && nano .env          # TELEGRAM_CHAT_ID como mínimo
sudo ./scripts/install-host.sh             # una vez: kubeconfig, paquetes del host, Cockpit, ACL del journal y de /var/log/pods, fail2ban
./scripts/install.sh                       # sin sudo: pide el token de Telegram la primera vez
./scripts/probar-alerta.sh                 # debe llegar un mensaje a Telegram
./scripts/status.sh
```

`install.sh` es idempotente. Para actualizar: `git pull && ./scripts/install.sh`. Cada ejecución aplica los manifiestos con `kubectl apply --server-side` y reinicia los pods del monitoreo para que lean la configuración nueva.

`generar-config.sh` deja en `~/.config/monitoreo` la configuración renderizada y un `kustomization.yaml` que usa `k8s/base` del repo (y `k8s/postgres` si hay PostgreSQL). Para inspeccionar lo que se aplica: `kubectl kustomize ~/.config/monitoreo`.

Secretos (fuera del repo, permisos 600). `install.sh` los carga como Secret del namespace `monitoreo`:

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
2. Copia los bloques de `acceso/ssh_config.ejemplo` a `%USERPROFILE%\.ssh\config` y ajusta host, puerto y usuario.
3. `.\acceso\conectar.ps1` (desde fuera de casa, por Cloudflare) o `.\acceso\conectar.ps1 -Lan` (en la LAN).

Abre Grafana en `http://localhost:13000` y Cockpit en `http://localhost:19090`. Ctrl+C cierra el túnel.

## Alertas

Reglas en `prometheus/reglas/servidor.yml` (fijas), `prometheus/reglas/kubernetes.yml` (registro de contenedores y alertas del clúster), `prometheus/reglas/especificas.yml` (generada desde `.env`) y `loki/reglas/seguridad.yml` (LogQL).

| Grupo | Alertas |
|---|---|
| Host | sin métricas, CPU, memoria, swap, carga, disco bajo, disco lleno en 24 h, inodos, temperatura, SMART, reloj, reinicio, reinicio requerido, paquetes pendientes, servicio del sistema `failed` |
| Servicios críticos | servicio del sistema o de usuario caído o ausente (listas en `.env`) |
| Red | interfaz caída, señal WiFi débil, errores de red, router inaccesible, sin internet |
| Túnel | sin conexiones, degradado, errores hacia las apps |
| Apps | caída interna, caída solo por Cloudflare, lentitud, certificado por vencer |
| Contenedores | detenido, unhealthy (no Ready), reinicios en bucle, memoria cerca del límite |
| Kubernetes | nodo no Ready, nodo con presión de memoria, disco o PID, pod en Pending, contenedor en CrashLoopBackOff o sin imagen, réplicas incompletas, DaemonSet incompleto, Job fallido, PVC sin enlazar |
| Seguridad | ráfaga de SSH fallidos, login root, login SSH (info), baneos de fail2ban, sudo con clave incorrecta, puerto abierto en todas las interfaces fuera de la lista permitida |
| Ataques web (por app) | fuerza bruta en el login (por IP y distribuida), escaneo de rutas, ráfaga de errores 4xx, ráfaga de peticiones. Las reglas filtran por el contenedor `traefik` (el Ingress de k3s), `minga-frontend` y `solarlink-frontend`; ajústalas en `loki/reglas/seguridad.yml` a tus contenedores |
| Kernel | OOM kill, errores de disco |
| Monitoreo | objetivo caído, recolector detenido, notificaciones fallidas, Watchdog |

Cada contenedor se identifica como `namespace/pod/contenedor` en la etiqueta `name`. Las reglas de registro de `kubernetes.yml` traducen kube-state-metrics y cAdvisor a `monitoreo_contenedor_*`, que usan los dashboards y las alertas de contenedores. Un contenedor de un Job terminado con éxito no cuenta como detenido.

## Puntos a validar en el servidor

- **Logs de pods.** Alloy los lee de `/var/log/pods` gracias a una ACL por defecto que pone `install-host.sh`. Si el dashboard **Contenedores** no muestra logs, vuelve a ejecutarlo.
- **Puertos de k3s.** k3s escucha en todas las interfaces en 6443, 10250 y, con Traefik, 80 y 443. Están en `PUERTOS_PUBLICOS_PERMITIDOS` del ejemplo; si no los quieres expuestos, restríngelos con el firewall.
- **Puerto de métricas de cloudflared.** Sin `metrics:` fijo en `/etc/cloudflared/config.yml`, cloudflared elige otro puerto al reiniciar y Prometheus pierde el túnel. `install-host.sh` lo revisa.
- **fail2ban y el puerto de SSH.** La jail `sshd` por defecto protege el 22. Si sshd escucha en otro puerto, define `port = <puerto>` en `/etc/fail2ban/jail.local`. El SSH que entra por cloudflared llega desde `127.0.0.1` y fail2ban lo ignora: protégelo con una política de Cloudflare Access.

## Desinstalar

```bash
./scripts/uninstall.sh                # quita pods, ConfigMaps, Secrets y RBAC; conserva los PVC y la configuración
./scripts/uninstall.sh --purge-datos  # borra el namespace monitoreo (con sus PVC) y ~/.config/monitoreo
```

Los paquetes del host (node-exporter, Cockpit) se quitan con `apt`. k3s no se toca.
