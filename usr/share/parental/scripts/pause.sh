#!/bin/ash
# Pause a client by MAC for N minutes; stores pause_until in UCI

MAC="$1"
DURATION_MIN="$2"

[ -z "$MAC" ] && exit 1
[ -z "$DURATION_MIN" ] && exit 1

# Find client index by MAC
IDX=""
uci -q show parental | sed -n "s/^parental\\.@client\\[\([0-9]\+\)\\]\\.mac='\([^']\+\)'.*/\1 \2/p" | while read I M; do
  if [ "$M" = "$MAC" ]; then echo "$I"; break; fi
done | {
  read IDX
  [ -z "$IDX" ] && exit 1
  # Compute pause-until epoch
  if date -u +%s >/dev/null 2>&1; then
    NOW=$(date +%s)
  else
    NOW=$(busybox date +%s)
  fi
  PAUSE_UNTIL=$(( NOW + (DURATION_MIN * 60) ))
  uci set parental.@client[$IDX].pause_until="$PAUSE_UNTIL"
  uci commit parental
}

# Compute pause-until epoch
if date -u +%s >/dev/null 2>&1; then
  NOW=$(date +%s)
else
  NOW=$(busybox date +%s)
fi
PAUSE_UNTIL=$(( NOW + (DURATION_MIN * 60) ))

# Immediately block; scheduler will un/block as time passes
/usr/share/parental/scripts/block_now.sh "$MAC" >/dev/null 2>&1 || true
exit 0
