#!/bin/ash
UCI="/sbin/uci -q"
NFT="/usr/sbin/nft"
CURL="/usr/bin/curl"

UP_HUMAN=$(uptime 2>/dev/null | sed 's/.*up \(.*\), .* load .*/\1/')
UP_SECS=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
[ -z "$UP_SECS" ] && UP_SECS=0

NFT_BIN=$([ -x "$NFT" ] && echo ok || echo missing)
FW4_RULE=$($NFT list chain inet fw4 forward 2>/dev/null | grep -q 'kids_blocked' && echo present || echo missing)

AG_URL=$($UCI get parental.settings.adguard_url 2>/dev/null)
AG_TOKEN=$($UCI get parental.settings.adguard_token 2>/dev/null)
if [ -n "$AG_URL" ] && [ -x "$CURL" ]; then
  AG_CODE=$($CURL -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AG_TOKEN" "$AG_URL/control/status" 2>/dev/null || echo 000)
else
  AG_CODE=000
fi

printf '{"uptime_human":"%s","uptime_seconds":%s,"nft":"%s","fw4_chain":"%s","cron":"%s","adguard":"%s"}\n' \
  "$UP_HUMAN" "$UP_SECS" "$NFT_BIN" "$FW4_RULE" "$([ -f /etc/crontabs/root ] && echo ok || echo missing)" "$AG_CODE"
