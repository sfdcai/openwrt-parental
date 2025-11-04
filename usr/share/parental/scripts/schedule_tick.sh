#!/bin/ash
# Enforce schedules, pauses, and simple daily quota using nft counters

UCI="/sbin/uci -q"
NFT="/usr/sbin/nft"
LOGTAG="parental-schedule"

# Time helpers
EPOCH=$(date +%s 2>/dev/null || busybox date +%s)
DAY=$(date +%a 2>/dev/null | tr 'A-Z' 'a-z' | cut -c1-3)
HOURMIN=$(date +%H:%M 2>/dev/null || busybox date +%H:%M)

DEFAULT_POLICY=$($UCI get parental.settings.default_policy 2>/dev/null)
[ -z "$DEFAULT_POLICY" ] && DEFAULT_POLICY=allow

# Parse schedule string like "07:00-20:30;mon-fri" or "08:00-21:00;sat,sun"
in_schedule() {
  s="$1"
  tpart=${s%%;*}
  dpart=${s#*;}
  shour=${tpart%-*}; ehour=${tpart#*-}
  # check day
  okday=0
  # expand ranges into list
  if echo "$dpart" | grep -q '-'; then
    start=${dpart%-*}; start=${start%,*}
    end=${dpart#*-}
    # ordered list of days
    list="mon tue wed thu fri sat sun mon tue wed thu fri sat sun"
    # take slice from start to next occurrence of end
    seen=0; days=""
    for d in $list; do
      [ $seen -eq 0 ] && [ "$d" = "$start" ] && seen=1
      [ $seen -eq 1 ] && days="$days $d"
      if [ $seen -eq 1 ] && [ "$d" = "$end" ]; then
        break
      fi
    done
  else
    days=$(echo "$dpart" | tr ',' ' ')
  fi
  for d in $days; do [ "$d" = "$DAY" ] && okday=1 && break; done
  [ "$okday" = 1 ] || return 1
  # check time window (inclusive start, exclusive end)
  [ "$HOURMIN" '\>=' "$shour" ] && [ "$HOURMIN" '\<' "$ehour" ]
}

group_schedules() {
  grp="$1"
  $UCI show parental | awk -v g="$grp" '
    $0 ~ /^config group/ { sect=""; }
    $0 ~ /^config group/ && $0 ~ /\047" g "\047/ { sect="1"; }
    sect=="1" && $0 ~ /\.schedule=/ {
      sub(/.*=\047/, ""); sub(/\047.*/, ""); print; }
  '
}

group_quota() {
  grp="$1"
  $UCI show parental | awk -v g="$grp" '
    $0 ~ /^config group/ { sect=""; }
    $0 ~ /^config group/ && $0 ~ /\047" g "\047/ { sect="1"; }
    sect=="1" && $0 ~ /\.quota_daily_min=/ {
      sub(/.*=\047/, ""); sub(/\047.*/, ""); print; exit; }
  '
}

allowed_now_for_group() {
  grp="$1"
  schedules=$(group_schedules "$grp")
  if [ -z "$schedules" ]; then
    [ "$DEFAULT_POLICY" = "allow" ] && return 0 || return 1
  fi
  for s in $schedules; do
    if in_schedule "$s"; then
      return 0
    fi
  done
  return 1
}

# nft helpers for counters
get_counter_bytes() {
  mac="$1"
  norm=$(echo "$mac" | tr -d ':' | tr 'A-F' 'a-f')
  $NFT list counters inet parental 2>/dev/null | awk -v n="c_"$norm' ' '/counter inet parental/ {seen=($3==n)} seen && /bytes/ {print $6; exit}'
}

STATE_DIR="/tmp/parental/quota/$(date +%Y%m%d 2>/dev/null || busybox date +%Y%m%d)"
mkdir -p "$STATE_DIR" >/dev/null 2>&1 || true

BLOCK_LIST_TMP=$(mktemp)

# Iterate clients
$UCI show parental | awk '
  /^parental\.@client\[[0-9]+\]\.mac=/ {mac=$0; sub(/.*=\047/,"",mac); sub(/\047.*/,"",mac); idx=$0; sub(/parental\.@client\[/, "", idx); sub(/\].*/, "", idx); print idx " " mac; }
' | while read IDX MAC; do
  GRP=$($UCI get parental.@client[$IDX].group 2>/dev/null)
  PAUSE=$($UCI get parental.@client[$IDX].pause_until 2>/dev/null)
  [ -z "$GRP" ] && GRP=""

  BLOCK="0"
  # Pause check
  if [ -n "$PAUSE" ] && [ "$PAUSE" -gt "$EPOCH" ] 2>/dev/null; then
    BLOCK="1"
  else
    if allowed_now_for_group "$GRP"; then
      BLOCK="0"
    else
      BLOCK="1"
    fi
    # Quota check if currently allowed by schedule
    if [ "$BLOCK" = "0" ]; then
      Q=$(group_quota "$GRP")
      if [ -n "$Q" ]; then
        STATE_FILE="$STATE_DIR/$(echo "$MAC" | tr ':' '_')"
        CUR_BYTES=$(get_counter_bytes "$MAC")
        [ -z "$CUR_BYTES" ] && CUR_BYTES=0
        LAST_BYTES=0; USED_MIN=0
        if [ -f "$STATE_FILE" ]; then
          LAST_BYTES=$(sed -n '1p' "$STATE_FILE" 2>/dev/null)
          USED_MIN=$(sed -n '2p' "$STATE_FILE" 2>/dev/null)
        fi
        if [ "$CUR_BYTES" -gt "$LAST_BYTES" ] 2>/dev/null; then
          USED_MIN=$((USED_MIN + 1))
        fi
        echo "$CUR_BYTES" >"$STATE_FILE"
        echo "$USED_MIN" >>"$STATE_FILE"
        if [ "$USED_MIN" -ge "$Q" ] 2>/dev/null; then
          BLOCK="1"
        fi
      fi
    fi
  fi

  if [ "$BLOCK" = "1" ]; then
    echo "$MAC" >>"$BLOCK_LIST_TMP"
  fi
done

# Read current blocked set
CUR_TMP=$(mktemp)
$NFT list set inet parental kids_blocked 2>/dev/null | sed -n 's/.*elements = { \(.*\) }.*/\1/p' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' >"$CUR_TMP" || true

# Add missing blocks
if [ -s "$BLOCK_LIST_TMP" ]; then
  while read M; do
    grep -iq "^$M$" "$CUR_TMP" || $NFT add element inet parental kids_blocked { $M } >/dev/null 2>&1 || true
  done <"$BLOCK_LIST_TMP"
fi

# Remove stale blocks
if [ -s "$CUR_TMP" ]; then
  while read M; do
    grep -iq "^$M$" "$BLOCK_LIST_TMP" || $NFT delete element inet parental kids_blocked { $M } >/dev/null 2>&1 || true
  done <"$CUR_TMP"
fi

rm -f "$BLOCK_LIST_TMP" "$CUR_TMP" 2>/dev/null || true
logger -t "$LOGTAG" "tick applied"
