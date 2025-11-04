#!/bin/ash
# Telegram bot bridge for Parental Suite v2

set -eu

LOGTAG="parental-telegram"
UCI="/sbin/uci -q"
UBUS="${UBUS_BIN:-/bin/ubus}"
CURL="${CURL_BIN:-/usr/bin/curl}"
LUA_BIN="${LUA_BIN:-$(command -v lua 2>/dev/null || command -v luajit 2>/dev/null)}"

log() {
  logger -t "$LOGTAG" "$*" 2>/dev/null || true
  printf '%s\n' "[$LOGTAG] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing dependency: $1"
    exit 1
  }
}

require_cmd "$UBUS"
require_cmd "$CURL"
require_cmd mktemp
[ -n "$LUA_BIN" ] || { log "lua interpreter not available"; exit 1; }

TOKEN="${TELEGRAM_TOKEN:-$($UCI get parental.settings.telegram_token 2>/dev/null)}"
CHAT_ALLOWED_RAW="${TELEGRAM_CHAT_ID:-$($UCI get parental.settings.telegram_chat_id 2>/dev/null)}"
[ -n "$TOKEN" ] || { log "telegram_token not configured"; exit 1; }
[ -n "$CHAT_ALLOWED_RAW" ] || { log "telegram_chat_id not configured"; exit 1; }

CHAT_ALLOWED="$(printf '%s' "$CHAT_ALLOWED_RAW" | tr ',;' '  ')"
BASE_URL="https://api.telegram.org/bot$TOKEN"
STATE_DIR="/tmp/parental/telegram"
mkdir -p "$STATE_DIR"
OFFSET_FILE="$STATE_DIR/offset"

if [ -f "$OFFSET_FILE" ]; then
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
else
  OFFSET=0
fi

send_message() {
  chat_id="$1"
  shift
  msg="$*"
  [ -n "$msg" ] || msg="(empty)"
  "$CURL" -sS -X POST "$BASE_URL/sendMessage" \
    -d "chat_id=$chat_id" \
    --data-urlencode "text=$msg" >/dev/null 2>&1 || true
}

format_status() {
  "$UBUS" call parental get_overview '{}' 2>/dev/null | "$LUA_BIN" - <<'EOF'
local json = require 'luci.jsonc'
local raw = io.read('*a') or ''
local data = json.parse(raw) or {}
local groups = data.groups or {}
local clients = data.clients or {}
local gcount = 0
for _ in pairs(groups) do gcount = gcount + 1 end
local ccount = 0
for _ in pairs(clients) do ccount = ccount + 1 end
local lines = {}
lines[#lines+1] = string.format('Groups: %d | Clients: %d', gcount, ccount)
for mac, c in pairs(clients) do
  local name = c.name or mac
  local group = c.group or '—'
  local paused = c.pause_until and tonumber(c.pause_until) or 0
  if paused > 0 then
    lines[#lines+1] = string.format('%s (%s) paused until %d', name, group, paused)
  else
    lines[#lines+1] = string.format('%s (%s)', name, group)
  end
end
print(table.concat(lines, '\n'))
EOF
}

format_health() {
  "$UBUS" call parental health '{}' 2>/dev/null | "$LUA_BIN" - <<'EOF'
local json = require 'luci.jsonc'
local raw = io.read('*a') or ''
local data = json.parse(raw) or {}
local lines = {}
for k,v in pairs(data) do
  lines[#lines+1] = string.format('%s: %s', k, v)
end
print(table.concat(lines, '\n'))
EOF
}

call_ubus() {
  obj="$1"; method="$2"; payload="$3"
  "$UBUS" call "$obj" "$method" "$payload" 2>/dev/null
}

is_allowed_chat() {
  cid="$1"
  for allowed in $CHAT_ALLOWED; do
    [ "$cid" = "$allowed" ] && return 0
  done
  return 1
}

handle_command() {
  chat_id="$1"
  text="$2"
  set -- $text
  cmd="$1"
  shift || true
  case "$cmd" in
    /status)
      msg=$(format_status)
      send_message "$chat_id" "$msg"
      ;;
    /health)
      msg=$(format_health)
      send_message "$chat_id" "$msg"
      ;;
    /apply)
      call_ubus parental apply '{}' >/dev/null 2>&1
      send_message "$chat_id" "Rules re-applied."
      ;;
    /sync)
      call_ubus parental sync_adguard '{}' >/dev/null 2>&1
      send_message "$chat_id" "AdGuard sync triggered."
      ;;
    /pause)
      mac="${1:-}"
      dur="${2:-30}"
      [ -n "$mac" ] || { send_message "$chat_id" "Usage: /pause <mac> [minutes]"; return; }
      case "$dur" in
        *[!0-9]*) dur=30 ;;
      esac
      payload=$(printf '{"mac":"%s","duration":%s}' "$mac" "$dur")
      call_ubus parental pause_client "$payload" >/dev/null 2>&1
      send_message "$chat_id" "Paused $mac for $dur minute(s)."
      ;;
    /block)
      mac="${1:-}"
      [ -n "$mac" ] || { send_message "$chat_id" "Usage: /block <mac>"; return; }
      payload=$(printf '{"mac":"%s"}' "$mac")
      call_ubus parental block_client "$payload" >/dev/null 2>&1
      send_message "$chat_id" "Blocked $mac."
      ;;
    /unblock)
      mac="${1:-}"
      [ -n "$mac" ] || { send_message "$chat_id" "Usage: /unblock <mac>"; return; }
      payload=$(printf '{"mac":"%s"}' "$mac")
      call_ubus parental unblock_client "$payload" >/dev/null 2>&1
      send_message "$chat_id" "Unblocked $mac."
      ;;
    /start)
      send_message "$chat_id" "Parental Suite bot ready."
      ;;
    *)
      send_message "$chat_id" "Unknown command: $cmd"
      ;;
  esac
}

parse_updates() {
  "$LUA_BIN" - <<'EOF'
local json = require 'luci.jsonc'
local raw = io.read('*a') or ''
local data = json.parse(raw)
if type(data) ~= 'table' or type(data.result) ~= 'table' then return end
for _, upd in ipairs(data.result) do
  local msg = upd.message or upd.edited_message
  if msg and msg.text and msg.chat then
    local text = (msg.text or ''):gsub('[\r\n\t]', ' ')
    local chat_id = tostring(msg.chat.id or '')
    local update_id = tostring(upd.update_id or '')
    print(string.format('%s\t%s\t%s', update_id, chat_id, text))
  end
end
EOF
}

run_once() {
  RESP="$1"
  NEW_OFFSET="$OFFSET"
  TMP=$(mktemp)
  printf '%s\n' "$RESP" | parse_updates >"$TMP"
  while IFS='\t' read -r upd_id chat_id cmd_text; do
    [ -n "$upd_id" ] && NEW_OFFSET="$upd_id"
    if ! is_allowed_chat "$chat_id"; then
      send_message "$chat_id" "Unauthorized chat."
      continue
    fi
    handle_command "$chat_id" "$cmd_text"
  done <"$TMP"
  rm -f "$TMP"
  if [ -n "$NEW_OFFSET" ]; then
    OFFSET="$NEW_OFFSET"
    printf '%s' "$OFFSET" >"$OFFSET_FILE"
  fi
}

log "starting bot loop"
while :; do
  NEXT=$((OFFSET + 1))
  RESPONSE=$("$CURL" -sS "$BASE_URL/getUpdates?timeout=25&offset=$NEXT" 2>/dev/null || echo '{}')
  run_once "$RESPONSE"
  [ "${RUN_ONCE:-0}" = "1" ] && break
  sleep 5
done
log "bot exiting"
