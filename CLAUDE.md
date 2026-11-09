# monitoreo-servidor (rama kubernetes)

Monitoreo de un servidor Linux (Ubuntu 24.04 o derivado) con k3s de un nodo. Se edita en la PC Windows (`C:\Users\ELITEBOOK\Desktop\Entorno\monitoreo`) y se instala en el servidor con `git clone -b kubernetes` + `scripts/install.sh`. Es un servidor distinto del que usa la rama `podman`.

## Ramas

- `podman` (rama por defecto), `docker` (Compose) y `kubernetes` (esta, Kustomize sobre k3s de un nodo). Son ramas permanentes con los mismos componentes, alertas y dashboards.
- La configuración compartida se cambia en `podman` y se lleva a las otras con `git cherry-pick`. Nunca se hace merge entre ramas: cada una reemplaza archivos de las otras.
- Archivos propios de esta rama: `k8s/`, `scripts/*` (kubectl en vez de Podman), `alloy/config.alloy` (añade logs de pods), `prometheus/prometheus.yml` (jobs `kube-state-metrics` y `kubelet-cadvisor`), `prometheus/reglas/kubernetes.yml`, las reglas de contenedores de `servidor.yml` y `generar-config.sh`, y los dashboards `contenedores`, `resumen` y `caracteristicas`. Al hacer cherry-pick de `podman`, esos archivos dan conflicto: se resuelve conservando las métricas de Kubernetes.

## Arquitectura

- Host (root, apt): `prometheus-node-exporter` en `127.0.0.1:9100` con colectores systemd, wifi y textfile, Cockpit en `127.0.0.1:9090` sin plugin de contenedores. `install-host.sh` además exige k3s activo con `local-path`, copia `/etc/rancher/k3s/k3s.yaml` a `~/.kube/config` del usuario, crea `/var/lib/monitoreo/alloy` (estado de Alloy, del usuario) y pone ACL de lectura con default en `/var/log/journal` y `/var/log/pods`.
- `k8s/base`: namespace `monitoreo`; Prometheus, Alertmanager, Loki y Grafana como StatefulSet con PVC `local-path`; blackbox y kube-state-metrics como Deployment con `strategy: Recreate`; Alloy como DaemonSet. `k8s/postgres` es un Component con postgres-exporter. No hay Services.
- Todos con `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`, escucha en `127.0.0.1` y sondas `httpGet` con `host: 127.0.0.1`. Por eso `prometheus.yml`, los datasources de Grafana y `conectar.ps1` no cambian respecto a `podman`. Con `hostNetwork`, un Deployment con RollingUpdate se bloquearía: el pod nuevo no puede abrir el puerto del viejo.
- Usuarios fijos por imagen (runAsNonRoot exige uid numérico): 65534 Prometheus, Alertmanager, blackbox, KSM y postgres-exporter; 10001 Loki; 472 Grafana. Alloy usa el uid y gid del usuario del host (parche JSON en el `kustomization.yaml` generado) para que valgan las ACL. Alloy guarda su estado en `/datos`, no en `/var/lib/alloy/data` (0770 del uid 473).
- `generar-config.sh` renderiza en `~/.config/monitoreo` y genera `kustomization.yaml` con `resources` relativo a `k8s/base` del repo (`realpath --relative-to`), `configMapGenerator`, `secretGenerator` desde `secretos/`, `disableNameSuffixHash` y la etiqueta `app.kubernetes.io/part-of=monitoreo`. Kustomize no admite archivos de generadores fuera de su raíz: por eso la raíz es el directorio de configuración y no el repo.
- `install.sh` aplica con `kubectl apply --server-side --force-conflicts -k` (el ConfigMap de dashboards supera el límite de la anotación del apply clásico) y luego `rollout restart` de todo lo etiquetado, porque los ConfigMaps no llevan hash.
- Prometheus lee cAdvisor del kubelet en `https://127.0.0.1:10250/metrics/cadvisor` con el token de su ServiceAccount (ClusterRole `nodes/metrics: get`) e `insecure_skip_verify`.
- `prometheus/reglas/kubernetes.yml` graba `monitoreo_contenedor_{estado,salud,arranque_segundos,cpu_segundos_total,memoria_bytes,memoria_limite_bytes,red_recibidos_bytes_total}` con `name = namespace/pod/contenedor` (`label_join`). Estado: 2 corriendo, 0 en espera, 5 terminado. Salud: 0 Ready, 1 corriendo sin Ready, -1 resto. Se excluyen los pods en fase `Succeeded`. Los valores se construyen sumando o restando al resultado de la comparación (`(x == 1) + 1`): multiplicar daría 0 o -0.
- Alloy lee el journal (`job=journal`) y `/var/log/pods/*/*/*.log` (`job=pods`, `stage.cri`) con etiquetas `namespace`, `pod` y `contenedor` sacadas de la ruta. Las reglas de ataques web filtran por `contenedor`.
- El recolector y su timer siguen igual que en `podman` (servicios de usuario, puertos, `monitoreo_servidor_info`).
- `uninstall.sh` sin `--purge-datos` borra lo etiquetado pero no el namespace: los PVC de los StatefulSet sobreviven. Con `--purge-datos` borra el namespace.

## Validar antes de subir

Con Podman local (`podman --connection podman-machine-default-root`) y un contenedor `rancher/k3s` desechable (`--privileged --tmpfs /run --tmpfs /var/run`, `--disable traefik`):

- Renderizar con `MONITOREO_ENV`, `MONITOREO_CONF_DIR` y `USAR_POSTGRES`, ajustar la ruta relativa de `k8s/` en el `kustomization.yaml`, copiar ambos al contenedor con tar y `kubectl apply --server-side -k`
- Todos los pods 1/1, objetivos `up`, sin errores en `/api/v1/rules`, series `monitoreo_contenedor_*` presentes, logs de pods en Loki (en la prueba no hay ACL: `chmod -R o+rX /var/log/pods`)
- Component de Postgres con un StatefulSet `postgres` de prueba y su Service
- `shellcheck -x -S warning scripts/*.sh` (imagen `koalaman/shellcheck-alpine`)
