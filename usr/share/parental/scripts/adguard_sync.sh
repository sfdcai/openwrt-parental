#!/bin/ash
UCI="/sbin/uci -q"
URL="$($UCI get parental.settings.adguard_url 2>/dev/null)"
TOKEN="$($UCI get parental.settings.adguard_token 2>/dev/null)"
[ -z "$URL" ] && exit 0
curl -sS -X POST -H "Authorization: Bearer $TOKEN" "$URL/control/clients" >/dev/null 2>&1 || logger -t parental "AdGuard sync failed"
