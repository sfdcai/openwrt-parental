#!/bin/sh
set -eu

log() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

fail() {
  printf '[-] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found. Install it via opkg."
}

if [ "$(id -u)" -ne 0 ]; then
  fail "Run this installer as root (connect as root over SSH or use sudo)."
fi

for cmd in cp find mkdir uci; do
  require_cmd "$cmd"
done

HTTPD_BIN="${HTTPD_BIN:-$(command -v httpd 2>/dev/null || true)}"
OPKG_BIN="${OPKG_BIN:-$(command -v opkg 2>/dev/null || true)}"

ensure_httpd() {
  if [ -n "$HTTPD_BIN" ]; then
    return 0
  fi

  if [ -z "$OPKG_BIN" ]; then
    return 1
  fi

  if ! "$OPKG_BIN" list-installed busybox-httpd >/dev/null 2>&1; then
    log "Installing busybox-httpd via opkg"
    if [ "${PARENTAL_SKIP_OPKG_UPDATE:-0}" != "1" ]; then
      log "Updating opkg package list"
      if ! "$OPKG_BIN" update; then
        warn "opkg update failed; continuing with install attempt"
      fi
    fi
    "$OPKG_BIN" install busybox-httpd >/dev/null 2>&1 || "$OPKG_BIN" install busybox-httpd || return 1
  fi

  HTTPD_BIN="${HTTPD_BIN:-$(command -v httpd 2>/dev/null || true)}"
  [ -n "$HTTPD_BIN" ]
}

if ! ensure_httpd; then
  fail "BusyBox httpd is required (install the 'busybox-httpd' package)."
fi
PIDOF_BIN="$(command -v pidof 2>/dev/null || true)"
UCI_BIN="$(command -v uci)"

UI_PORT="${PARENTAL_UI_PORT:-8088}"
UI_ROOT="/www/parental-ui"
PAYLOAD_ROOT="$(pwd)"

log "Creating target directories"
for dir in \
  /etc/config \
  /etc/init.d \
  /usr/share/parental/scripts \
  /usr/libexec/rpcd \
  /usr/share/rpcd/acl.d \
  "$UI_ROOT"; do
  mkdir -p "$dir"
done

log "Copying package files"
find "$PAYLOAD_ROOT" -mindepth 1 -type f ! -path "$PAYLOAD_ROOT/install.sh" -print0 | \
  while IFS= read -r -d '' src; do
    dest="/${src#"$PAYLOAD_ROOT"/}"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  done

if [ -f /etc/init.d/parental ]; then
  chmod +x /etc/init.d/parental
fi
if [ -d /usr/share/parental ]; then
  find /usr/share/parental -type f -name '*.sh' -exec chmod +x {} +
fi
if [ -f /usr/libexec/rpcd/parental ]; then
  chmod +x /usr/libexec/rpcd/parental
fi

run_initd() {
  svc="$1"
  action="$2"
  if [ -x "/etc/init.d/$svc" ]; then
    "/etc/init.d/$svc" "$action" >/dev/null 2>&1 || "/etc/init.d/$svc" "$action"
  else
    warn "Skipping /etc/init.d/$svc $action (service not installed)"
  fi
}

log "Enabling services"
run_initd parental enable
run_initd parental restart
run_initd rpcd restart

start_httpd() {
  if [ -n "$PIDOF_BIN" ]; then
    pid_list="$($PIDOF_BIN httpd 2>/dev/null || true)"
    if [ -n "$pid_list" ]; then
      log "Stopping existing httpd instance(s): $pid_list"
      kill $pid_list 2>/dev/null || true
    fi
  fi
  log "Starting UI httpd on port $UI_PORT"
  "$HTTPD_BIN" -p "$UI_PORT" -h "$UI_ROOT" &
}

start_httpd

LAN_IP="$($UCI_BIN get network.lan.ipaddr 2>/dev/null || true)"
if [ -z "$LAN_IP" ] && command -v ip >/dev/null 2>&1; then
  LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1)
fi
if [ -n "$LAN_IP" ]; then
  log "UI available at http://$LAN_IP:$UI_PORT"
else
  log "UI available on port $UI_PORT (check your router's LAN IP)."
fi
log "Installation complete"
