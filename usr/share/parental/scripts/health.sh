#!/bin/ash
echo "{"
echo "\"nft\": \"$([ -x /usr/sbin/nft ] && echo ok || echo missing)\","
echo "\"cron\": \"$([ -f /etc/crontabs/root ] && echo ok || echo missing)\","
echo "\"adguard\": \"$($(/usr/bin/curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/control/status 2>/dev/null || echo 000))\""
echo "}"
