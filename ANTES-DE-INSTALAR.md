# Antes de instalar el monitoreo (Kubernetes)

Lista de todo lo que hay que revisar, preparar y saber antes de ejecutar `install-host.sh` e `install.sh` en el servidor. Léela completa una vez; después usa las casillas como checklist.

Pensada para Ubuntu 24.04 o un derivado (Linux Mint 22) con k3s de un nodo.

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

- [ ] k3s instalado y activo (`systemctl is-active k3s`), con la StorageClass `local-path` (viene por defecto).
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
cat /etc/os-release | head -2; k3s --version | head -1
sudo k3s kubectl get nodes -o wide; sudo k3s kubectl get storageclass
loginctl show-user "$USER" -p Linger
ls /var/log/journal >/dev/null && echo journal-persistente
ss -Htln | awk '{print $4}' | grep -E ':(3000|3100|9090|9091|9093|9095|9100|9115|9187|9882|9883|12345)$' || echo "puertos libres"
grep -E '^metrics:' /etc/cloudflared/config.yml || systemctl cat cloudflared-tunel.service | grep -- --metrics || echo "SIN PUERTO DE MÉTRICAS FIJO"
sudo sshd -T | grep -E '^port '
sudo grep -rnE '^\s*(\[sshd\]|port\s*=|enabled\s*=)' /etc/fail2ban/jail.local /etc/fail2ban/jail.d/ 2>/dev/null
df -h /; free -h
```

### 2.1 Puertos

El monitoreo usa estos puertos, **todos en 127.0.0.1** (los pods usan la red del host, pero no se abre nada hacia la LAN ni a internet):

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
| 9882, 9883 | kube-state-metrics |
| 12345 | Alloy |

- [ ] Ninguno está ocupado.
- [ ] Prometheus lee el kubelet en `127.0.0.1:10250`, que k3s ya abre.

### 2.2 Puertos que abre k3s

k3s escucha en todas las interfaces en 6443 (API), 10250 (kubelet) y, si mantienes Traefik, en 80 y 443. La alerta `PuertoPublicoNoPermitido` los reportaría.

- [ ] `PUERTOS_PUBLICOS_PERMITIDOS` en `.env` incluye los puertos de k3s que usas. El ejemplo trae `22 80 443 6443 10250`.
- [ ] Si no necesitas 6443 ni 10250 desde la LAN, ciérralos con el firewall.

### 2.3 Puerto de métricas de cloudflared

Prometheus lee el túnel en `127.0.0.1:20250`. Si cloudflared no tiene ese puerto **fijo**, elige otro al reiniciar y el monitoreo pierde el túnel sin avisar (solo verás `ObjetivoCaido`).

- [ ] `/etc/cloudflared/config.yml` tiene `metrics: 127.0.0.1:20250`, o el servicio arranca con `--metrics 127.0.0.1:20250`.
- [ ] `CLOUDFLARED_METRICAS_PUERTO` en `.env` coincide con ese puerto.
- [ ] Si cloudflared corre como pod y no como servicio del host, publica sus métricas en `127.0.0.1` del host (`hostNetwork` o `hostPort`), o el job `cloudflared` quedará caído.
- [ ] Si el servidor no usa túnel de Cloudflare, quita `cloudflared-tunel.service` de `UNIDADES_SISTEMA_CRITICAS` y el job `cloudflared` de `prometheus/prometheus.yml`.

### 2.4 fail2ban y el puerto de SSH

- [ ] En `/etc/fail2ban/jail.local`, sección `[sshd]`: `enabled = true` y `port = <puerto de sshd>`.
- [ ] El SSH que entra por Cloudflare llega desde `127.0.0.1`, que fail2ban ignora. Protégelo con una aplicación de **Cloudflare Access**.

### 2.5 Red

- [ ] `INTERFAZ_RED` en `.env` es la interfaz que de verdad usa el servidor (`ip -br a`).
- [ ] `GATEWAY_LAN` es la IP del router (`ip route | grep default`).

### 2.6 Servicios y contenedores críticos

- [ ] `UNIDADES_SISTEMA_CRITICAS` contiene solo servicios que existen, incluido `k3s.service`. Uno inexistente dispara `ServicioSistemaAusente` para siempre.
- [ ] `UNIDADES_USUARIO_CRITICAS` contiene solo servicios de usuario que existen. Con Kubernetes suele quedar vacía.
- [ ] `CONTENEDORES_EXCLUIDOS` es una regex sobre `namespace/pod/contenedor` con los contenedores que pueden estar detenidos. Los Jobs terminados con éxito ya se excluyen solos.

### 2.7 Apps

- [ ] La URL interna de cada entrada de `APPS` responde desde el host (`curl -sI <url>`): un NodePort, un `hostPort` o el Ingress en `127.0.0.1`. Un Service ClusterIP no es alcanzable desde blackbox por IP de loopback; usa su nombre DNS (`http://app.namespace.svc.cluster.local`), que sí resuelve.
- [ ] Si alguna app pública está detrás de Cloudflare Access, la sonda externa recibe la página de login (200). Para esas apps la sonda interna es la que importa.
- [ ] Ajusta en `loki/reglas/seguridad.yml` y en el dashboard **Seguridad** los nombres de contenedor (`traefik`, `minga-frontend`, `solarlink-frontend`) a los de tus proxies o servidores web.

### 2.8 PostgreSQL

`install.sh` crea en el recurso `POSTGRES_CONTENEDOR` (por ejemplo `statefulset/postgres`) del namespace `POSTGRES_NAMESPACE` un rol **`monitoreo`** con permisos `pg_monitor` (solo lectura de estadísticas, sin acceso a tablas), con una clave aleatoria guardada en `~/.config/monitoreo/secretos/pg-password`.

- [ ] `POSTGRES_HOST` apunta a PostgreSQL visto desde el host: `127.0.0.1` si publica el puerto, o el nombre del Service (`postgres.db.svc.cluster.local`).
- [ ] El contenedor tiene `psql` y la variable `POSTGRES_USER` (imagen oficial). Si usa otro superusuario, el paso falla y hay que ajustarlo.
- [ ] `pg_hba.conf` acepta contraseña desde la IP del nodo (los pods con `hostNetwork` salen con ella). La imagen oficial lo permite por defecto.
- [ ] Si no quieres vigilar PostgreSQL, deja `POSTGRES_CONTENEDOR=""`.

---

## 3. Qué cambia en el servidor

### `install-host.sh` (con sudo)

| Cambio | Detalle | Impacto en las apps |
|---|---|---|
| kubeconfig | Copia `/etc/rancher/k3s/k3s.yaml` a `~/.kube/config` (600) si no existe, y crea el enlace `kubectl` si falta | Ninguno |
| Alloy | Crea `/var/lib/monitoreo/alloy`, de tu usuario | Ninguno |
| Paquetes apt | `prometheus-node-exporter`, `prometheus-node-exporter-collectors`, `smartmontools`, `acl`, `cockpit` | Ninguno |
| node-exporter | Sobrescribe `/etc/default/prometheus-node-exporter` (respaldo en `.orig`) para escuchar solo en loopback | Ninguno |
| Timers | Activa `prometheus-node-exporter-apt.timer` y `prometheus-node-exporter-smartmon.timer` | Ninguno |
| Cockpit | `cockpit.socket` solo en `127.0.0.1:9090` | Ninguno |
| Logs | ACL de lectura (con herencia) para tu usuario en `/var/log/journal` y `/var/log/pods` | Ninguno |
| Textfile | ACL de escritura para tu usuario en `/var/lib/prometheus/node-exporter` | Ninguno |
| fail2ban | Crea `/etc/fail2ban/fail2ban.d/monitoreo.local` (logs al journal) y **reinicia fail2ban** | Durante el reinicio se levantan los baneos activos y vuelven a aplicarse |
| Linger | Lo activa si no estaba | Ninguno |

No reinicia k3s, cloudflared, sshd ni tus pods.

### `install.sh` (con tu usuario)

- Crea `~/.config/monitoreo/` (configuración, secretos y `kustomization.yaml`).
- Instala y activa `monitoreo-recolector.timer` de usuario.
- Crea el namespace `monitoreo` con sus ConfigMaps, Secrets, StatefulSets, Deployments, el DaemonSet de Alloy, dos ServiceAccounts y dos ClusterRoles de solo lectura (`nodes/metrics` para Prometheus; listar pods, nodos y workloads para kube-state-metrics).
- Crea 4 PVC `local-path` (22 GiB solicitados en total; `local-path` no impone el tamaño).
- Descarga unos 1,2 GB de imágenes.
- Reinicia solo los pods del namespace `monitoreo`.

---

## 4. Recursos

| Recurso | Estimado |
|---|---|
| RAM | 1–1,5 GB en total. Los `limits` suman unos 3,5 GiB |
| Disco, imágenes | ~1,2 GB |
| Disco, Prometheus (30 días) | 1–3 GB, en `/var/lib/rancher/k3s/storage` |
| Disco, Loki (14 días) | 1–5 GB, según el volumen de logs |
| CPU | Bajo; picos breves al comprimir datos |

Las retenciones son fijas: 30 días de métricas y 14 días de logs. Para cambiarlas, edita `k8s/base/prometheus.yaml` (`--storage.tsdb.retention.time`) y `loki/loki.yml` (`retention_period`).

---

## 5. Seguridad

- Ningún componente escucha fuera de `127.0.0.1` y no se crea ningún Service. Desde la PC se entra solo con un túnel SSH.
- Los pods usan `hostNetwork`: comparten la red del host para llegar a servicios en loopback. Por eso corren sin root, con `readOnlyRootFilesystem`, sin capacidades y sin escalada de privilegios. El namespace se etiqueta con Pod Security `privileged` porque `hostNetwork` y `hostPath` no caben en los perfiles más estrictos.
- Prometheus tiene permiso para leer las métricas del kubelet; kube-state-metrics, para listar pods, nodos y workloads. Ninguno puede modificar nada.
- Prometheus no verifica el certificado del kubelet (es autofirmado). La conexión no sale de `127.0.0.1`.
- Alloy puede leer **todo** el journal del sistema y los logs de todos los pods. Esos logs quedan en Loki 14 días.
- Los secretos no están en el repo: viven en `~/.config/monitoreo/secretos/` (permisos 600) y como Secret del namespace `monitoreo`. Cualquiera con acceso de lectura a Secrets de ese namespace puede verlos.
- `~/.kube/config` es el kubeconfig de administrador de k3s: protégelo como una clave de root.
- `.env` no se versiona. Contiene el `chat_id` y la URL de latido, que no son secretos críticos, pero no los publiques.
- Cockpit da una terminal web con tu usuario y sudo. Solo es accesible por el túnel SSH.

---

## 6. Riesgos conocidos

| Riesgo | Qué pasa | Qué hacer |
|---|---|---|
| Sin ACL en `/var/log/pods` | Loki recibe el journal pero no los logs de los pods; las reglas de ataques web no ven nada | Vuelve a ejecutar `install-host.sh` |
| Varios nodos | `hostNetwork` y `hostPath` asumen un nodo; en otro nodo los pods no verían los servicios del host | Esta rama es para k3s de un nodo |
| Puerto ocupado al reiniciar | Con `hostNetwork`, dos pods del mismo componente no pueden coexistir | Los Deployments usan `Recreate`; no cambies la estrategia |
| Primera carga del journal | Alloy envía hasta 12 h de logs antiguos al arrancar | Puede disparar alertas de seguridad por eventos de esas 12 h; se resuelven solas |
| Alertas al estrenar | Es normal recibir varias alertas en la primera hora | Revísalas: suelen ser ajustes del `.env` |
| ICMP sin privilegios | blackbox corre con el gid 65534 y necesita `net.ipv4.ping_group_range` amplio | Si `GatewayInaccesible` salta con el router en pie: `sysctl net.ipv4.ping_group_range` debe mostrar `0 2147483647` |

---

## 7. Lo que el monitoreo no cubre

- **Servidor apagado o sin internet:** sin `HEALTHCHECKS_URL` no llega ningún aviso. Con él, avisa el servicio externo.
- **Métricas internas de las apps:** solo se ve si responden, cuánto tardan y sus logs.
- **Backups:** no se verifica que existan ni que funcionen (tampoco los de los PVC).
- **Plano de control de Kubernetes:** no se miden el API server, etcd ni el scheduler; solo el nodo, el kubelet y los workloads.
- **Otros equipos de la LAN:** solo se vigila este servidor y el router.

---

## 8. Orden de instalación

```bash
git clone -b kubernetes <repo> ~/monitoreo-servidor && cd ~/monitoreo-servidor
cp .env.example .env && nano .env          # chat_id, gateway, listas de servicios
sudo ./scripts/install-host.sh             # revisa los avisos que imprime
./scripts/install.sh                       # pide el token de Telegram la primera vez
./scripts/probar-alerta.sh                 # debe llegar a Telegram en ~30 s
./scripts/status.sh                        # todos los pods Running y los objetivos "ok"
```

En la PC:

```powershell
# pega los bloques de acceso\ssh_config.ejemplo en %USERPROFILE%\.ssh\config y ajusta host, puerto y usuario
.\acceso\conectar.ps1 -Lan                 # o sin -Lan desde fuera de casa
```

## 9. Verificación después de instalar

- [ ] Llegó el mensaje de `probar-alerta.sh` a Telegram.
- [ ] `status.sh` muestra todos los pods `Running` y todos los objetivos en `ok`.
- [ ] Grafana abre en `http://localhost:13000` (usuario `admin`, clave en `~/.config/monitoreo/secretos/grafana-admin`).
- [ ] El dashboard **Contenedores** muestra estado, CPU, memoria y logs de tus pods.
- [ ] El dashboard **Logs** muestra entradas de `sshd`, `kernel` y `k3s`.
- [ ] Prueba real: `kubectl scale deployment/<app> --replicas=0` → en 10 min llega `ReplicasIncompletas` (y antes `AppInternaCaida`) → vuelve a escalar → llega el aviso de resuelto.
- [ ] Reinicia el servidor en un horario tranquilo y confirma que todo vuelve solo y que llega `ServidorReiniciado`.
- [ ] Al día siguiente llegó el `Watchdog` diario (en silencio).

## 10. Cómo deshacerlo

```bash
./scripts/uninstall.sh                # quita pods, ConfigMaps, Secrets y RBAC; conserva PVC y configuración
./scripts/uninstall.sh --purge-datos  # además borra el namespace (con sus PVC) y ~/.config/monitoreo
```

Lado host, si quieres revertirlo por completo:

```bash
sudo apt-get remove prometheus-node-exporter prometheus-node-exporter-collectors cockpit
sudo rm -f /etc/fail2ban/fail2ban.d/monitoreo.local && sudo systemctl restart fail2ban
sudo rm -rf /etc/systemd/system/cockpit.socket.d /var/lib/monitoreo && sudo systemctl daemon-reload
sudo setfacl -Rx "u:$USER" /var/log/journal /var/log/pods
```

El rol `monitoreo` de PostgreSQL se quita con `DROP ROLE monitoreo;` dentro del pod de PostgreSQL.
