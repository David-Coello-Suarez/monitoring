# Antes de instalar el monitoreo

Lista de todo lo que hay que revisar, preparar y saber antes de ejecutar `install-host.sh` e `install.sh` en el servidor. Léela completa una vez; después usa las casillas como checklist.

Datos del servidor tomados el 2026-11-07: Linux Mint 22 (Ubuntu 24.04 noble), Podman 4.9.3, usuario `david_coello` (uid 1000), linger activo, journal persistente, 15 GB de RAM (13 GB disponibles), 399 GB libres en `/`, red por WiFi USB `wlx7cc2c62db6b8` (192.168.100.59), cable `eno1` desconectado.

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

- [ ] Acceso SSH con tu usuario (`ssh -p 97 david_coello@192.168.100.59` o por `ssh.circutbytes.tech`).
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
cat /etc/upstream-release/lsb-release; podman --version
loginctl show-user "$USER" -p Linger
ls /var/log/journal >/dev/null && echo journal-persistente
ss -Htln | awk '{print $4}' | grep -E ':(3000|3100|9090|9091|9093|9095|9100|9115|9187|9882|12345)$' || echo "puertos libres"
grep -E '^metrics:' /etc/cloudflared/config.yml || systemctl cat cloudflared-tunel.service | grep -- --metrics || echo "SIN PUERTO DE MÉTRICAS FIJO"
sudo sshd -T | grep -E '^port '
sudo grep -rnE '^\s*(\[sshd\]|port\s*=|enabled\s*=)' /etc/fail2ban/jail.local /etc/fail2ban/jail.d/ 2>/dev/null
grep -rh noble-backports /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null | head -1 || echo "sin backports"
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
| 9882 | podman-exporter |
| 12345 | Alloy |

- [ ] Ninguno está ocupado. El 2026-11-07 estaban libres; vuelve a revisarlo si instalaste algo después.

### 2.2 Puerto de métricas de cloudflared

Prometheus lee el túnel en `127.0.0.1:20250`. Si cloudflared no tiene ese puerto **fijo**, elige otro al reiniciar y el monitoreo pierde el túnel sin avisar (solo verás `ObjetivoCaido`).

- [ ] `/etc/cloudflared/config.yml` tiene `metrics: 127.0.0.1:20250`, o el servicio arranca con `--metrics 127.0.0.1:20250`.
- [ ] Si no lo tiene: agrégalo y ejecuta `sudo systemctl restart cloudflared-tunel`. El reinicio corta las apps unos segundos.
- [ ] `CLOUDFLARED_METRICAS_PUERTO` en `.env` coincide con ese puerto.

### 2.3 fail2ban y el puerto 97

La jail `sshd` de fail2ban protege por defecto el puerto 22. Tu sshd escucha en el 97.

- [ ] En `/etc/fail2ban/jail.local`, sección `[sshd]`: `enabled = true` y `port = 97`.
- [ ] Recuerda: el SSH que entra por `ssh.circutbytes.tech` llega desde `127.0.0.1`, que fail2ban ignora. Esa entrada solo está protegida por Cloudflare.
- [ ] `ssh.circutbytes.tech` tiene una aplicación de **Cloudflare Access** con política limitada a tu correo. Compruébalo en Zero Trust → Access → Applications.

### 2.4 Red

- [ ] `INTERFAZ_RED` en `.env` es la interfaz que de verdad usa el servidor (`ip -br a`). Hoy: `wlx7cc2c62db6b8`.
- [ ] `GATEWAY_LAN` es la IP del router (`ip route | grep default`). Se asumió `192.168.100.1`: **confírmalo**.
- [ ] Considera conectar el cable `eno1`. Con WiFi USB, si el adaptador se cuelga caen las apps, el túnel y los avisos al mismo tiempo. Si cambias a cable, actualiza `INTERFAZ_RED` y vuelve a ejecutar `install.sh`.

### 2.5 Servicios críticos

Las listas de `.env` deciden qué servicios disparan alerta **critical** si se caen o desaparecen.

- [ ] `UNIDADES_SISTEMA_CRITICAS` contiene solo servicios que existen (`systemctl list-units --type=service`). Uno inexistente dispara `ServicioSistemaAusente` para siempre.
- [ ] `UNIDADES_USUARIO_CRITICAS` contiene solo servicios de usuario que existen (`systemctl --user list-units --type=service`). Hoy: `minga`, `frontend`, `solarlink-frontend`, `postgres-demo`.
- [ ] Los servicios oneshot (como `solarlink-frontend-autodeploy`) **no** van en la lista: terminan y quedan inactivos a propósito.
- [ ] `CONTENEDORES_EXCLUIDOS` incluye los contenedores que se detienen a propósito (migraciones, tareas de una sola vez). Si no, saltará `ContenedorDetenido`.
- [ ] `PUERTOS_PUBLICOS_PERMITIDOS` tiene los puertos que pueden escuchar en `0.0.0.0`. Hoy: `97` (sshd) y `5432` (postgres-demo, solo LAN).

### 2.6 Apps

- [ ] Cada entrada de `APPS` responde con 2xx o 3xx: `curl -sI http://127.0.0.1:8081` (y 8082, 8083), `curl -sI https://otsmart.circutbytes.tech` (y los otros dominios).
- [ ] Si alguna app pública está detrás de Cloudflare Access, la sonda externa recibe la página de login (200) y la marca como disponible. Eso confirma que el túnel funciona, no que la app responda. Para esas apps la sonda interna es la que importa.

### 2.7 PostgreSQL

`install.sh` crea en `postgres-demo` un rol **`monitoreo`** con permisos `pg_monitor` (solo lectura de estadísticas, sin acceso a tablas), con una clave aleatoria guardada en `~/.config/monitoreo/secretos/pg-password`.

- [ ] Estás de acuerdo con crear ese rol en `postgres-demo`.
- [ ] El contenedor tiene la variable `POSTGRES_USER` (imagen oficial). Si usa otro superusuario, el paso falla y hay que ajustarlo.
- [ ] `pg_hba.conf` permite conexiones por contraseña desde `127.0.0.1`. Es el valor por defecto de la imagen oficial.
- [ ] Si no quieres vigilar PostgreSQL, deja `POSTGRES_CONTENEDOR=""`.

---

## 3. Qué cambia en el servidor

### `install-host.sh` (con sudo)

| Cambio | Detalle | Impacto en las apps |
|---|---|---|
| Paquetes apt | `prometheus-node-exporter`, `prometheus-node-exporter-collectors`, `smartmontools`, `acl`, `cockpit`, `cockpit-podman` | Ninguno |
| node-exporter | Sobrescribe `/etc/default/prometheus-node-exporter` (respaldo en `.orig`) para escuchar solo en loopback | Ninguno |
| Timers | Activa `prometheus-node-exporter-apt.timer` y `prometheus-node-exporter-smartmon.timer` | Ninguno |
| Cockpit | `cockpit.socket` solo en `127.0.0.1:9090` (override en `/etc/systemd/system/cockpit.socket.d/loopback.conf`) | Ninguno |
| Journal | ACL de lectura para tu usuario en `/var/log/journal` | Ninguno |
| Textfile | ACL de escritura para tu usuario en `/var/lib/prometheus/node-exporter` | Ninguno |
| fail2ban | Crea `/etc/fail2ban/fail2ban.d/monitoreo.local` (logs al journal) y **reinicia fail2ban** | Durante el reinicio se levantan los baneos activos y vuelven a aplicarse |
| Linger | Lo activa si no estaba (ya está activo) | Ninguno |

No reinicia `user@1000.service`, cloudflared, sshd ni tus contenedores.

### `install.sh` (con tu usuario)

- Crea `~/.config/monitoreo/` (configuración y secretos) y los Quadlet `~/.config/containers/systemd/mon-*.container`.
- Crea los secretos de Podman `mon-telegram-token`, `mon-grafana-admin` y `mon-pg-password`.
- Activa `podman.socket` de usuario (lo necesitan podman-exporter y Cockpit).
- Ejecuta `systemctl --user daemon-reload`. Esto regenera **todas** tus unidades Quadlet, también las de minga, krivot y solarlink, pero **no las reinicia**. Si alguna tiene un cambio pendiente sin aplicar en su `.container`, quedará cargada la versión nueva y se aplicará en su próximo reinicio.
- Descarga unos 1,2 GB de imágenes.
- Solo reinicia los servicios `mon-*`.

---

## 4. Recursos

| Recurso | Estimado | Disponible |
|---|---|---|
| RAM | 1–1,5 GB en total (Prometheus y Grafana son los mayores) | 13 GB |
| Disco, imágenes | ~1,2 GB | 399 GB |
| Disco, Prometheus (30 días) | 1–3 GB | |
| Disco, Loki (14 días) | 1–5 GB, según el volumen de logs | |
| CPU | Bajo; picos breves al comprimir datos | |

Las retenciones son fijas: 30 días de métricas y 14 días de logs. Para cambiarlas, edita `quadlet/mon-prometheus.container` (`--storage.tsdb.retention.time`) y `loki/loki.yml` (`retention_period`).

---

## 5. Seguridad

- Ningún componente escucha fuera de `127.0.0.1`. Desde la PC se entra solo con un túnel SSH.
- Todos los contenedores usan `Network=host`: comparten la red del host para llegar a servicios en loopback. Por eso se endurecen con `ReadOnly`, `DropCapability=ALL` y `NoNewPrivileges`, y corren rootless.
- podman-exporter accede al socket de Podman de tu usuario: puede **leer** el estado de todos tus contenedores (no los modifica, pero el socket permitiría hacerlo). Es la misma confianza que se le da a Cockpit.
- Alloy puede leer **todo** el journal del sistema, incluidos los logs de autenticación. Esos logs quedan en Loki 14 días.
- Los secretos no están en el repo: viven en `~/.config/monitoreo/secretos/` (permisos 600) y como `podman secret`.
- `.env` no se versiona. Contiene el `chat_id` y la URL de latido, que no son secretos críticos, pero no los publiques.
- Cockpit da una terminal web con tu usuario y sudo. Solo es accesible por el túnel SSH.

---

## 6. Riesgos conocidos

| Riesgo | Qué pasa | Qué hacer |
|---|---|---|
| podman-exporter v1.21.2 con Podman 4.9 | Se eligió antes de la v2.0.0 por compatibilidad, pero no se probó contra 4.9 | Si `status.sh` muestra `podman` caído, revisa `journalctl --user -u mon-podman-exporter -n 50` |
| Directivas Quadlet en Podman 4.9 | `Secret=`, `Tmpfs=` y `UserNS=keep-id:uid=` deberían funcionar en 4.9, pero solo se validaron en Podman 6 | Si un servicio no arranca: `/usr/libexec/podman/quadlet -dryrun -user` muestra el error |
| Cockpit desde backports | Si Mint no tiene `noble-backports` habilitado, se instala la versión del repositorio principal (más antigua) | Funciona igual; solo cambia la versión |
| Primera carga del journal | Alloy envía hasta 12 h de logs antiguos al arrancar | Puede disparar alertas de seguridad por eventos de esas 12 h; se resuelven solas |
| Alertas al estrenar | Es normal recibir varias alertas en la primera hora (unidades huérfanas, autodeploy atascado, paquetes pendientes) | Revísalas: son los hallazgos ya conocidos o ajustes del `.env` |
| ICMP sin privilegios | blackbox necesita `net.ipv4.ping_group_range` amplio para hacer ping como usuario | Si `GatewayInaccesible` salta con el router en pie: `sysctl net.ipv4.ping_group_range` debe mostrar `0 2147483647` |

---

## 7. Lo que el monitoreo no cubre

- **Servidor apagado o sin internet:** sin `HEALTHCHECKS_URL` no llega ningún aviso. Con él, avisa el servicio externo.
- **Métricas internas de las apps:** no se miden peticiones, errores ni tiempos dentro de minga, krivot o solarlink. Solo se ve si responden, cuánto tardan y sus logs.
- **Backups:** no se verifica que existan ni que funcionen.
- **Otros equipos de la LAN:** solo se vigila este servidor y el router.

---

## 8. Orden de instalación

```bash
git clone <repo> ~/monitoreo-servidor && cd ~/monitoreo-servidor
cp .env.example .env && nano .env          # chat_id, gateway, listas de servicios
sudo ./scripts/install-host.sh             # revisa los avisos que imprime
./scripts/install.sh                       # pide el token de Telegram la primera vez
./scripts/probar-alerta.sh                 # debe llegar a Telegram en ~30 s
./scripts/status.sh                        # todos los objetivos "ok"
```

En la PC:

```powershell
Copy-Item acceso\ssh_config.ejemplo -Destination $env:USERPROFILE\.ssh\config-monitoreo
# pega los bloques en %USERPROFILE%\.ssh\config
.\acceso\conectar.ps1 -Lan                 # o sin -Lan desde fuera de casa
```

## 9. Verificación después de instalar

- [ ] Llegó el mensaje de `probar-alerta.sh` a Telegram.
- [ ] `status.sh` muestra todos los objetivos en `ok`.
- [ ] Grafana abre en `http://localhost:13000` (usuario `admin`, clave en `~/.config/monitoreo/secretos/grafana-admin`).
- [ ] El dashboard **Resumen** muestra las tres apps en OK, por dentro y por fuera.
- [ ] El dashboard **Logs** muestra entradas de `sshd`, `kernel` y de tus contenedores. Si está vacío, falta la ACL del journal: vuelve a ejecutar `install-host.sh`.
- [ ] Cockpit abre en `http://localhost:19090` y la pestaña **Podman containers** lista tus contenedores.
- [ ] Prueba real: `systemctl --user stop solarlink-frontend` → en 2–3 min llega `ServicioUsuarioCaido` y `AppInternaCaida` → `systemctl --user start solarlink-frontend` → llega el aviso de resuelto.
- [ ] Reinicia el servidor en un horario tranquilo y confirma que todo vuelve solo y que llega `ServidorReiniciado`.
- [ ] Al día siguiente llegó el `Watchdog` diario (en silencio).

## 10. Cómo deshacerlo

```bash
./scripts/uninstall.sh                # quita servicios, timer y secretos; conserva datos
./scripts/uninstall.sh --purge-datos  # además borra volúmenes y ~/.config/monitoreo
```

Lado host, si quieres revertirlo por completo:

```bash
sudo apt-get remove prometheus-node-exporter prometheus-node-exporter-collectors cockpit cockpit-podman
sudo rm -f /etc/fail2ban/fail2ban.d/monitoreo.local && sudo systemctl restart fail2ban
sudo rm -rf /etc/systemd/system/cockpit.socket.d && sudo systemctl daemon-reload
sudo setfacl -Rx "u:$USER" /var/log/journal
```

El rol `monitoreo` de PostgreSQL se quita con `DROP ROLE monitoreo;` dentro de `postgres-demo`.
