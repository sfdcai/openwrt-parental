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

OPKG_BIN="${OPKG_BIN:-$(command -v opkg 2>/dev/null || true)}"
UCI_BIN="$(command -v uci)"

UI_PORT="${PARENTAL_UI_PORT:-8088}"
UI_ROOT="/www/parental-ui"
PAYLOAD_ROOT="$(pwd)"

OPKG_UPDATED=0

ensure_package() {
  pkg="$1"
  [ -n "$OPKG_BIN" ] || return 1
  if "$OPKG_BIN" list-installed "$pkg" >/dev/null 2>&1; then
    return 0
  fi
  if [ "${PARENTAL_SKIP_OPKG_UPDATE:-0}" != "1" ] && [ $OPKG_UPDATED -eq 0 ]; then
    log "Updating opkg package list"
    if "$OPKG_BIN" update >/dev/null 2>&1; then
      OPKG_UPDATED=1
    else
      warn "opkg update failed; continuing with install attempts"
      OPKG_UPDATED=1
    fi
  fi
  log "Installing package $pkg"
  "$OPKG_BIN" install "$pkg" >/dev/null 2>&1 || "$OPKG_BIN" install "$pkg"
}

ensure_command() {
  cmd="$1"
  shift
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  for pkg in "$@"; do
    if ensure_package "$pkg"; then
      command -v "$cmd" >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

NEEDED_PACKAGES="uhttpd uhttpd-mod-ubus luci-lib-jsonc lua curl"
for pkg in $NEEDED_PACKAGES; do
  ensure_package "$pkg" || warn "Failed to ensure package $pkg (install manually)"
done

ensure_command curl curl || fail "curl is required"
ensure_command lua lua luajit || fail "Lua interpreter is required"

ensure_uhttpd() {
  if [ -x /etc/init.d/uhttpd ]; then
    return 0
  fi

  if [ -z "$OPKG_BIN" ]; then
    return 1
  fi

  if ! "$OPKG_BIN" list-installed uhttpd >/dev/null 2>&1; then
    log "Installing uhttpd via opkg"
    if [ "${PARENTAL_SKIP_OPKG_UPDATE:-0}" != "1" ]; then
      log "Updating opkg package list"
      if ! "$OPKG_BIN" update; then
        warn "opkg update failed; continuing with install attempt"
      fi
    fi
    "$OPKG_BIN" install uhttpd >/dev/null 2>&1 || "$OPKG_BIN" install uhttpd || return 1
  fi

  [ -x /etc/init.d/uhttpd ]
}

if ! ensure_uhttpd; then
  fail "uHTTPd is required (install the 'uhttpd' package)."
fi

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

configure_uhttpd() {
  section="parental"
  if ! "$UCI_BIN" -q get uhttpd.$section >/dev/null 2>&1; then
    "$UCI_BIN" set uhttpd.$section=uhttpd
  fi

  "$UCI_BIN" set uhttpd.$section.home="$UI_ROOT"
  "$UCI_BIN" set uhttpd.$section.index_page='index.html'
  "$UCI_BIN" set uhttpd.$section.realm='Parental Suite'
  "$UCI_BIN" set uhttpd.$section.rfc1918_filter='1'
  "$UCI_BIN" set uhttpd.$section.redirect_https='0'
  "$UCI_BIN" -q delete uhttpd.$section.ubus_prefix >/dev/null 2>&1 || true
  "$UCI_BIN" add_list uhttpd.$section.ubus_prefix='/ubus'
  "$UCI_BIN" -q delete uhttpd.$section.network >/dev/null 2>&1 || true
  "$UCI_BIN" add_list uhttpd.$section.network='lan'
  "$UCI_BIN" -q delete uhttpd.$section.listen_http >/dev/null 2>&1 || true
  "$UCI_BIN" add_list uhttpd.$section.listen_http="0.0.0.0:$UI_PORT"

  "$UCI_BIN" commit uhttpd

  run_initd uhttpd enable
  run_initd uhttpd reload
}

log "Configuring uHTTPd for UI on port $UI_PORT"
configure_uhttpd

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
