#!/usr/bin/env bash

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPTS_DIR")"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/monitoreo"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
ENV_FILE="${MONITOREO_ENV:-$REPO_DIR/.env}"
NAMESPACE=monitoreo
ETIQUETA=app.kubernetes.io/part-of=monitoreo
ALLOY_DIR=/var/lib/monitoreo/alloy

if [[ -t 1 ]]; then
  C_INFO=$'\033[1;34m' C_OK=$'\033[1;32m' C_WARN=$'\033[1;33m' C_ERR=$'\033[1;31m' C_END=$'\033[0m'
else
  C_INFO='' C_OK='' C_WARN='' C_ERR='' C_END=''
fi

info() { printf '%s==>%s %s\n' "$C_INFO" "$C_END" "$*"; }
ok() { printf '%s ok%s %s\n' "$C_OK" "$C_END" "$*"; }
warn() { printf '%saviso:%s %s\n' "$C_WARN" "$C_END" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$C_ERR" "$C_END" "$*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "falta el comando '$cmd'."
  done
}

require_non_root() {
  [[ "$(id -u)" -ne 0 ]] || die "ejecuta este script con tu usuario, no como root."
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "ejecuta este script con sudo."
}

require_user_systemd() {
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || ! systemctl --user show-environment >/dev/null 2>&1; then
    die "no hay sesión de systemd --user. Entra con 'ssh $USER@host' (no 'sudo su')."
  fi
}

require_kubectl() {
  local version
  version="$(kubectl version -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | tail -1)"
  [[ -n "$version" ]] || die "kubectl no llega al clúster. Ejecuta primero: sudo ./scripts/install-host.sh (copia ~/.kube/config)."
  ok "kubernetes $version"
}

k() {
  kubectl -n "$NAMESPACE" "$@"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "no existe $ENV_FILE. Copia .env.example a .env y complétalo."
  set -a
  . "$ENV_FILE"
  set +a
}

join_regex() {
  local IFS='|'
  printf '%s' "$*"
}

wait_http() {
  local url="$1" name="$2" timeout="${3:-120}" waited=0
  until curl -fsS -o /dev/null "$url"; do
    ((waited >= timeout)) && {
      warn "$name no respondió en ${timeout}s ($url)."
      return 1
    }
    sleep 3
    ((waited += 3))
  done
  ok "$name responde"
}
