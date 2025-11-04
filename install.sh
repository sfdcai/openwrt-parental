#!/bin/sh
set -e
echo "[+] Installing Parental Suite v2"
for d in /etc/config /etc/init.d /usr/share/parental/scripts /usr/libexec/rpcd /usr/share/rpcd/acl.d /www/parental-ui; do mkdir -p "$d"; done
find . -type f ! -name install.sh -print0 | while IFS= read -r -d '' f; do
  dest="/$(echo "$f"|sed 's|^./||')"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done
chmod +x /etc/init.d/parental /usr/share/parental/scripts/*.sh /usr/libexec/rpcd/parental
/etc/init.d/parental enable
/etc/init.d/parental start
/etc/init.d/rpcd restart
httpd -p 8088 -h /www/parental-ui &
echo "[+] UI on http://$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1):8088"
