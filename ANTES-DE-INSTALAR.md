# Antes de instalar el monitoreo (Docker)

Lista de todo lo que hay que revisar, preparar y saber antes de ejecutar `install-host.sh` e `install.sh` en el servidor. Léela completa una vez; después usa las casillas como checklist.

Pensada para Ubuntu 24.04 o un derivado (Linux Mint 22) con Docker Engine y el plugin Compose v2.

---

## 1. Qué hay que tener listo

### Telegram

- [ ] Bot creado con `@BotFather`. Guarda el **token** en un lugar seguro: `install.sh` lo pide una sola vez y no se muestra en pantalla.
- [ ] Le escribiste al bot al menos un mensaje (o lo agregaste al grupo donde quieres los avisos). Sin eso, Telegram no le deja enviarte nada.
- [ ] Tienes el **chat_id**: abre `https://api.telegram.org/bot<token>/getUpdates` y copia `chat.id`. En grupos es un número negativo (`-100...`).

### Latido externo (opcional, recomendado)

- [ ] Cuenta en healthchecks.io (u otro servicio de "dead man's switch") con un check de periodo 5 min y gracia de 5–10 min.
- [ ] URL de ping copiada para `HEALTHCHECKS_URL`.

Sin esto, si el servidor pierde internet o se apaga, **nadie te avisa**: Telegram depende de que el propio servidor tenga red. El latido externo es lo único que cubre ese caso.

### En el servidor

- [ ] Docker Engine instalado y activo (`docker version`), con el plugin Compose v2 (`docker compose version`).
- [ ] Tu usuario está en el grupo `docker` (`id -nG`). Si lo acabas de añadir, cierra sesión y reinicia el gestor de usuario: `sudo systemctl restart user@$(id -u).service`.
- [ ] Acceso SSH con tu usuario.
- [ ] Conoces la contraseña de `sudo` (`install-host.sh` la pide).
- [ ] `git` instalado (`git --version`).
- [ ] El repo está en GitHub y el servidor puede clonarlo (repo privado: llave SSH de despliegue o token).

### En la PC

- [ ] Cliente OpenSSH de Windows (`ssh -V`).
- [ ] `cloudflared` para entrar desde fuera de casa: `winget install --id Cloudflare.cloudflared`.
- [ ] Llave SSH de la PC autorizada en el servidor (`~/.ssh/authorized_keys`), para no escribir la clave en cada túnel.

---

## 2. Revisiones en el servidor antes de instalar

Ejecuta esto y revisa cada punto:

```bash
cat /etc/os-release | head -2; docker version --format '{{.Server.Version}}'; docker compose version
docker info --format 'logs={{.LoggingDriver}} cgroup={{.CgroupVersion}}'
ls -l /run/containerd/containerd.sock
loginctl show-user "$USER" -p Linger
ls /var/log/journal >/dev/null && echo journal-persistente
ss -Htln | awk '{print $4}' | grep -E ':(3000|3100|9090|9091|9093|9095|9100|9115|9187|9882|12345)$' || echo "puertos libres"
grep -E '^metrics:' /etc/cloudflared/config.yml || systemctl cat cloudflared-tunel.service | grep -- --metrics || echo "SIN PUERTO DE MÉTRICAS FIJO"
sudo sshd -T | grep -E '^port '
sudo grep -rnE '^\s*(\[sshd\]|port\s*=|enabled\s*=)' /etc/fail2ban/jail.local /etc/fail2ban/jail.d/ 2>/dev/null
df -h /; free -h
```

### 2.1 Puertos

El monitoreo usa estos puertos, **todos en 127.0.0.1** (no se abre nada hacia la LAN ni a internet):

| Puerto | Servicio |
|---|---|
| 3000 | Grafana |
| 3100, 9095 | Loki |
| 9090 | Cockpit |
| 9091 | Prometheus |
| 9093 | Alertmanager |
| 9100 | node-exporter |
| 9115 | blackbox |
| 9187 | postgres-exporter |
| 9882 | cAdvisor |
| 12345 | Alloy |

- [ ] Ninguno está ocupado.

### 2.2 Logs de Docker en el journal

Alloy lee el journal. Los logs de tus contenedores solo llegan a Loki si Docker usa el driver `journald`. Sin eso, el dashboard **Logs** no muestra tus apps y las reglas de ataques web no ven nada.

- [ ] `docker info --format '{{.LoggingDriver}}'` muestra `journald`.
- [ ] Si no: agrega `"log-driver": "journald"` a `/etc/docker/daemon.json`, ejecuta `sudo systemctl restart docker` y recrea tus contenedores (`docker compose up -d --force-recreate` en cada proyecto). El reinicio de Docker detiene todos los contenedores unos segundos.

### 2.3 Puerto de métricas de cloudflared

Prometheus lee el túnel en `127.0.0.1:20250`. Si cloudflared no tiene ese puerto **fijo**, elige otro al reiniciar y el monitoreo pierde el túnel sin avisar (solo verás `ObjetivoCaido`).

- [ ] `/etc/cloudflared/config.yml` tiene `metrics: 127.0.0.1:20250`, o el servicio arranca con `--metrics 127.0.0.1:20250`.
- [ ] `CLOUDFLARED_METRICAS_PUERTO` en `.env` coincide con ese puerto.
- [ ] Si el servidor no usa túnel de Cloudflare, quita `cloudflared-tunel.service` de `UNIDADES_SISTEMA_CRITICAS`. El objetivo `cloudflared` quedará caído: ignora `ObjetivoCaido` para ese job o bórralo de `prometheus/prometheus.yml`.

### 2.4 fail2ban y el puerto de SSH

- [ ] En `/etc/fail2ban/jail.local`, sección `[sshd]`: `enabled = true` y `port = <puerto de sshd>`.
- [ ] El SSH que entra por Cloudflare llega desde `127.0.0.1`, que fail2ban ignora. Protégelo con una aplicación de **Cloudflare Access**.

### 2.5 Red

- [ ] `INTERFAZ_RED` en `.env` es la interfaz que de verdad usa el servidor (`ip -br a`).
- [ ] `GATEWAY_LAN` es la IP del router (`ip route | grep default`).

### 2.6 Servicios y contenedores críticos

- [ ] `UNIDADES_SISTEMA_CRITICAS` contiene solo servicios que existen (`systemctl list-units --type=service`), incluido `docker.service`. Uno inexistente dispara `ServicioSistemaAusente` para siempre.
- [ ] `UNIDADES_USUARIO_CRITICAS` contiene solo servicios de usuario que existen. Con Docker suele quedar vacía.
- [ ] `CONTENEDORES_EXCLUIDOS` incluye los contenedores que se detienen a propósito (migraciones, tareas de una sola vez). Si no, saltará `ContenedorDetenido`.
- [ ] `PUERTOS_PUBLICOS_PERMITIDOS` tiene los puertos que pueden escuchar en `0.0.0.0`. Los puertos publicados por Docker (`-p 8080:80`) escuchan en todas las interfaces salvo que los publiques como `127.0.0.1:8080:80`.

### 2.7 Apps

- [ ] Cada entrada de `APPS` responde con 2xx o 3xx: `curl -sI <url interna>` y `curl -sI <url externa>`.
- [ ] Si alguna app pública está detrás de Cloudflare Access, la sonda externa recibe la página de login (200). Para esas apps la sonda interna es la que importa.
- [ ] Ajusta en `loki/reglas/seguridad.yml` y en el dashboard **Seguridad** los nombres de contenedor (`traefik`, `minga-frontend`, `solarlink-frontend`) a los de tus proxies o servidores web.

### 2.8 PostgreSQL

`install.sh` crea en el contenedor `POSTGRES_CONTENEDOR` un rol **`monitoreo`** con permisos `pg_monitor` (solo lectura de estadísticas, sin acceso a tablas), con una clave aleatoria guardada en `~/.config/monitoreo/secretos/pg-password`.

- [ ] El contenedor publica PostgreSQL en `127.0.0.1:POSTGRES_PUERTO` del host (postgres-exporter usa la red del host).
- [ ] El contenedor tiene la variable `POSTGRES_USER` (imagen oficial). Si usa otro superusuario, el paso falla y hay que ajustarlo.
- [ ] Si no quieres vigilar PostgreSQL, deja `POSTGRES_CONTENEDOR=""`.

---

## 3. Qué cambia en el servidor

### `install-host.sh` (con sudo)

| Cambio | Detalle | Impacto en las apps |
|---|---|---|
| Comprobaciones | Docker, Compose v2, usuario en el grupo `docker`, driver de logs | Ninguno: solo avisa |
| Paquetes apt | `prometheus-node-exporter`, `prometheus-node-exporter-collectors`, `smartmontools`, `acl`, `cockpit` | Ninguno |
| node-exporter | Sobrescribe `/etc/default/prometheus-node-exporter` (respaldo en `.orig`) para escuchar solo en loopback | Ninguno |
| Timers | Activa `prometheus-node-exporter-apt.timer` y `prometheus-node-exporter-smartmon.timer` | Ninguno |
| Cockpit | `cockpit.socket` solo en `127.0.0.1:9090` | Ninguno |
| Journal | ACL de lectura para tu usuario en `/var/log/journal` | Ninguno |
| Textfile | ACL de escritura para tu usuario en `/var/lib/prometheus/node-exporter` | Ninguno |
| fail2ban | Crea `/etc/fail2ban/fail2ban.d/monitoreo.local` (logs al journal) y **reinicia fail2ban** | Durante el reinicio se levantan los baneos activos y vuelven a aplicarse |
| Linger | Lo activa si no estaba | Ninguno |

No reinicia Docker, cloudflared, sshd ni tus contenedores.

### `install.sh` (con tu usuario)

- Crea `~/.config/monitoreo/` (configuración, secretos y `compose.env`) y `~/.local/share/monitoreo/` (datos).
- Instala y activa `monitoreo-recolector.timer` de usuario.
- Descarga unos 1,3 GB de imágenes.
- Recrea solo los contenedores del proyecto Compose `monitoreo` (`mon-*`). No toca tus otros contenedores.

---

## 4. Recursos

| Recurso | Estimado |
|---|---|
| RAM | 1–1,5 GB en total (Prometheus y Grafana son los mayores) |
| Disco, imágenes | ~1,3 GB |
| Disco, Prometheus (30 días) | 1–3 GB |
| Disco, Loki (14 días) | 1–5 GB, según el volumen de logs |
| CPU | Bajo; picos breves al comprimir datos |

Las retenciones son fijas: 30 días de métricas y 14 días de logs. Para cambiarlas, edita `compose.yml` (`--storage.tsdb.retention.time`) y `loki/loki.yml` (`retention_period`).

---

## 5. Seguridad

- Ningún componente escucha fuera de `127.0.0.1`. Desde la PC se entra solo con un túnel SSH.
- Todos los contenedores usan `network_mode: host`: comparten la red del host para llegar a servicios en loopback. Por eso corren con tu uid y se endurecen con `read_only`, `cap_drop: ALL` y `no-new-privileges`.
- **cAdvisor corre `privileged`** y monta `/`, `/sys`, `/var/run` y `/var/lib/docker` en solo lectura. Es la única forma de leer los cgroups de todos los contenedores. Escucha solo en loopback.
- **El grupo `docker` equivale a root** en el host: quien lo tenga puede montar cualquier archivo en un contenedor. El recolector lo necesita para `docker inspect`.
- Alloy puede leer **todo** el journal del sistema, incluidos los logs de autenticación. Esos logs quedan en Loki 14 días.
- Los secretos no están en el repo: viven en `~/.config/monitoreo/secretos/` (permisos 600).
- `.env` no se versiona. Contiene el `chat_id` y la URL de latido, que no son secretos críticos, pero no los publiques.
- Cockpit da una terminal web con tu usuario y sudo. Solo es accesible por el túnel SSH.

---

## 6. Riesgos conocidos

| Riesgo | Qué pasa | Qué hacer |
|---|---|---|
| Socket de containerd en otra ruta | cAdvisor no ve los contenedores por nombre y los paneles de CPU y memoria quedan vacíos | Si `ls /run/containerd/containerd.sock` falla, añade `--containerd=<ruta>` al comando de `mon-cadvisor` en `compose.yml` |
| Gestor de usuario sin el grupo `docker` | El recolector falla y salta `RecolectorDetenido` | `install.sh` lo detecta; reinicia `user@<uid>.service` |
| Primera carga del journal | Alloy envía hasta 12 h de logs antiguos al arrancar | Puede disparar alertas de seguridad por eventos de esas 12 h; se resuelven solas |
| Alertas al estrenar | Es normal recibir varias alertas en la primera hora | Revísalas: suelen ser ajustes del `.env` |
| ICMP sin privilegios | blackbox necesita `net.ipv4.ping_group_range` amplio para hacer ping con tu uid | Si `GatewayInaccesible` salta con el router en pie: `sysctl net.ipv4.ping_group_range` debe mostrar `0 2147483647` |

---

## 7. Lo que el monitoreo no cubre

- **Servidor apagado o sin internet:** sin `HEALTHCHECKS_URL` no llega ningún aviso. Con él, avisa el servicio externo.
- **Métricas internas de las apps:** solo se ve si responden, cuánto tardan y sus logs.
- **Backups:** no se verifica que existan ni que funcionen.
- **Otros equipos de la LAN:** solo se vigila este servidor y el router.

---

## 8. Orden de instalación

```bash
git clone -b docker <repo> ~/monitoreo-servidor && cd ~/monitoreo-servidor
cp .env.example .env && nano .env          # chat_id, gateway, listas de servicios
sudo ./scripts/install-host.sh             # revisa los avisos que imprime
./scripts/install.sh                       # pide el token de Telegram la primera vez
./scripts/probar-alerta.sh                 # debe llegar a Telegram en ~30 s
./scripts/status.sh                        # todos los objetivos "ok"
```

En la PC:

```powershell
# pega los bloques de acceso\ssh_config.ejemplo en %USERPROFILE%\.ssh\config y ajusta host, puerto y usuario
.\acceso\conectar.ps1 -Lan                 # o sin -Lan desde fuera de casa
```

## 9. Verificación después de instalar

- [ ] Llegó el mensaje de `probar-alerta.sh` a Telegram.
- [ ] `status.sh` muestra todos los contenedores `Up` y todos los objetivos en `ok`.
- [ ] Grafana abre en `http://localhost:13000` (usuario `admin`, clave en `~/.config/monitoreo/secretos/grafana-admin`).
- [ ] El dashboard **Contenedores** muestra estado, CPU y memoria de tus contenedores.
- [ ] El dashboard **Logs** muestra entradas de `sshd`, `kernel` y de tus contenedores. Si faltan las de contenedores, revisa el driver de logs (2.2).
- [ ] Prueba real: `docker stop <app>` → en 3 min llega `ContenedorDetenido` y `AppInternaCaida` → `docker start <app>` → llega el aviso de resuelto.
- [ ] Reinicia el servidor en un horario tranquilo y confirma que todo vuelve solo (`restart: always`) y que llega `ServidorReiniciado`.
- [ ] Al día siguiente llegó el `Watchdog` diario (en silencio).

## 10. Cómo deshacerlo

```bash
./scripts/uninstall.sh                # quita contenedores y timer; conserva datos
./scripts/uninstall.sh --purge-datos  # además borra ~/.local/share/monitoreo y ~/.config/monitoreo
```

Lado host, si quieres revertirlo por completo:

```bash
sudo apt-get remove prometheus-node-exporter prometheus-node-exporter-collectors cockpit
sudo rm -f /etc/fail2ban/fail2ban.d/monitoreo.local && sudo systemctl restart fail2ban
sudo rm -rf /etc/systemd/system/cockpit.socket.d && sudo systemctl daemon-reload
sudo setfacl -Rx "u:$USER" /var/log/journal
```

El rol `monitoreo` de PostgreSQL se quita con `DROP ROLE monitoreo;` dentro del contenedor.
