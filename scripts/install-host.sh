#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

require_root
USUARIO="${SUDO_USER:-${1:-}}"
[[ -n "$USUARIO" && "$USUARIO" != root ]] || die "uso: sudo $0 (desde tu usuario) o sudo $0 <usuario>"
id "$USUARIO" >/dev/null 2>&1 || die "no existe el usuario $USUARIO"
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
export DEBIAN_FRONTEND=noninteractive
HOME_USUARIO="$(getent passwd "$USUARIO" | cut -d: -f6)"

info "k3s"
systemctl is-active --quiet k3s || die "k3s no está activo. Instálalo antes (https://get.k3s.io) y vuelve a ejecutar este script."
k3s kubectl get storageclass local-path >/dev/null 2>&1 || die "k3s no tiene la StorageClass local-path."
if [[ ! -s "$HOME_USUARIO/.kube/config" ]]; then
  install -d -m 0700 -o "$USUARIO" -g "$(id -gn "$USUARIO")" "$HOME_USUARIO/.kube"
  install -m 0600 -o "$USUARIO" -g "$(id -gn "$USUARIO")" /etc/rancher/k3s/k3s.yaml "$HOME_USUARIO/.kube/config"
  ok "kubeconfig copiado a $HOME_USUARIO/.kube/config"
else
  ok "$HOME_USUARIO/.kube/config ya existe"
fi
command -v kubectl >/dev/null 2>&1 || ln -s "$(command -v k3s)" /usr/local/bin/kubectl
install -d -m 0750 -o "$USUARIO" -g "$(id -gn "$USUARIO")" "$ALLOY_DIR"
ok "estado de Alloy en $ALLOY_DIR"

info "Paquetes base"
apt-get update -qq
apt-get install -y -qq prometheus-node-exporter prometheus-node-exporter-collectors smartmontools acl >/dev/null
ok "node-exporter, colectores, smartmontools y acl"

info "node-exporter solo en loopback, con systemd, wifi y textfile"
defaults=/etc/default/prometheus-node-exporter
[[ -f "$defaults.orig" ]] || cp -a "$defaults" "$defaults.orig"
cat >"$defaults" <<EOF
ARGS="--web.listen-address=127.0.0.1:9100 --collector.systemd --collector.systemd.unit-include=.+\\.(service|timer|socket) --collector.wifi --collector.textfile.directory=$TEXTFILE_DIR"
EOF
install -d -m 0755 "$TEXTFILE_DIR"
setfacl -m "u:$USUARIO:rwx" "$TEXTFILE_DIR"
systemctl restart prometheus-node-exporter
systemctl enable prometheus-node-exporter >/dev/null
for timer in prometheus-node-exporter-apt.timer prometheus-node-exporter-smartmon.timer; do
  if systemctl list-unit-files "$timer" >/dev/null 2>&1; then
    systemctl enable --now "$timer" >/dev/null && ok "$timer"
  else
    warn "$timer no existe en este paquete"
  fi
done

info "Cockpit solo en 127.0.0.1:9090"
codename="$(. /etc/upstream-release/lsb-release 2>/dev/null && echo "${DISTRIB_CODENAME:-}")"
if [[ -n "$codename" ]] && apt-get install -y -qq -t "$codename-backports" cockpit >/dev/null 2>&1; then
  ok "cockpit desde $codename-backports"
else
  apt-get install -y -qq cockpit >/dev/null
  ok "cockpit desde el repositorio principal"
fi
install -d /etc/systemd/system/cockpit.socket.d
cat >/etc/systemd/system/cockpit.socket.d/loopback.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=127.0.0.1:9090
EOF
systemctl daemon-reload
systemctl enable cockpit.socket >/dev/null
systemctl restart cockpit.socket

info "Lectura del journal completo para $USUARIO (ACL, sin cambiar grupos)"
setfacl -Rnm "u:$USUARIO:rX,d:u:$USUARIO:rX" /var/log/journal
ok "/var/log/journal"
install -d -m 0755 /var/log/pods
setfacl -Rnm "u:$USUARIO:rX,d:u:$USUARIO:rX" /var/log/pods
ok "/var/log/pods (logs de los pods)"

info "fail2ban registra en el journal"
if command -v fail2ban-client >/dev/null 2>&1; then
  cat >/etc/fail2ban/fail2ban.d/monitoreo.local <<'EOF'
[Definition]
logtarget = SYSTEMD-JOURNAL
EOF
  systemctl restart fail2ban
  ok "fail2ban → journal"
  puerto_ssh="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
  puerto_jail="$(grep -rhE '^\s*port\s*=' /etc/fail2ban/jail.local /etc/fail2ban/jail.d/ 2>/dev/null | head -1 | tr -d ' ' || true)"
  echo "    sshd escucha en el puerto ${puerto_ssh:-?}; jail: ${puerto_jail:-port=ssh (22, por defecto)}"
else
  warn "fail2ban no está instalado"
fi

info "Métricas de cloudflared"
ss -Htlnp | grep cloudflared | awk '{print "    escucha en " $4}' || warn "cloudflared no expone métricas"
if systemctl cat cloudflared-tunel.service 2>/dev/null | grep -q -- '--metrics'; then
  ok "cloudflared-tunel tiene --metrics fijo"
elif grep -qs '^metrics:' /etc/cloudflared/config.yml; then
  ok "config.yml tiene metrics fijo"
else
  warn "cloudflared no fija el puerto de métricas. Agrega 'metrics: 127.0.0.1:20250' a /etc/cloudflared/config.yml y reinicia cloudflared-tunel."
fi

info "Usuario $USUARIO"
[[ "$(loginctl show-user "$USUARIO" -p Linger --value 2>/dev/null)" == yes ]] || {
  loginctl enable-linger "$USUARIO"
  ok "linger activado"
}
ok "linger"

wait_http http://127.0.0.1:9100/metrics node-exporter 30
curl -fsS http://127.0.0.1:9100/metrics | grep -q '^node_systemd_unit_state' && ok "colector systemd" || warn "sin métricas systemd"
wait_http http://127.0.0.1:9090/ cockpit 30 || true

info "Listo. Ahora, como $USUARIO (sin sudo): ./scripts/install.sh"
