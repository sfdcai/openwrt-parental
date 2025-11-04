#!/bin/sh
set -e
WORKDIR="$(pwd)/parental_suite_v2"
ZIPFILE="$(pwd)/parental_suite_v2.zip"

echo "[+] Building Parental Suite v2 in $WORKDIR"
rm -rf "$WORKDIR" "$ZIPFILE"
mkdir -p \
  "$WORKDIR/etc/config" \
  "$WORKDIR/etc/init.d" \
  "$WORKDIR/usr/share/parental/scripts" \
  "$WORKDIR/usr/libexec/rpcd" \
  "$WORKDIR/usr/share/rpcd/acl.d" \
  "$WORKDIR/www/parental-ui"

# ------------------------------
# 1) /etc/config/parental
# ------------------------------
cat > "$WORKDIR/etc/config/parental" <<'EOF'
config global 'settings'
  option enabled '1'
  option default_policy 'allow'
  option adguard_url 'http://127.0.0.1:3000'
  option adguard_token ''
  option log_level 'info'

config group 'kids'
  option name 'Kids'
  option dns_profile 'kids'
  option schedule '07:00-20:30;mon-fri'
  option schedule '08:00-21:00;sat-sun'
  list clients 'AA:BB:CC:DD:EE:01'

config client
  option mac 'AA:BB:CC:DD:EE:01'
  option name 'KidPhone'
  option group 'kids'
  option pause_until ''
EOF

# ------------------------------
# 2) /etc/init.d/parental
# ------------------------------
cat > "$WORKDIR/etc/init.d/parental" <<'EOF'
#!/bin/sh /etc/rc.common
START=98
USE_PROCD=1
NAME=parental
start_service(){
  /usr/share/parental/scripts/apply.sh boot
  grep -q schedule_tick.sh /etc/crontabs/root 2>/dev/null || {
    echo '* * * * * /usr/share/parental/scripts/schedule_tick.sh >/dev/null 2>&1' >>/etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1
  }
  httpd -p 8088 -h /www/parental-ui &
}
reload_service(){ /usr/share/parental/scripts/apply.sh reload; }
EOF

# ------------------------------
# 3) ACL
# ------------------------------
cat > "$WORKDIR/usr/share/rpcd/acl.d/parental.json" <<'EOF'
{
  "parental": {
    "description": "Parental Suite RPCD ACL",
    "read": {
      "ubus": [ "parental", "session", "uci", "file", "system" ]
    },
    "write": {
      "ubus": [ "parental", "uci" ]
    }
  }
}
EOF

# ------------------------------
# 4) RPCD plugin
# ------------------------------
cat > "$WORKDIR/usr/libexec/rpcd/parental" <<'EOF'
#!/usr/bin/lua
-- rpcd plugin providing parental.* methods
local json=require"luci.jsonc"
local function sh(c) local f=io.popen(c.." 2>&1");local o=f:read("*a");f:close();return o end
local M,methods={},{}
methods.get_overview={args={},call=function()return 0,{uci=sh("uci -q show parental") }end}
methods.apply={args={},call=function()return 0,{out=sh("/usr/share/parental/scripts/apply.sh reload") }end}
methods.health={args={},call=function()return 0,{out=sh("/usr/share/parental/scripts/health.sh") }end}
methods.sync_adguard={args={},call=function()return 0,{out=sh("/usr/share/parental/scripts/adguard_sync.sh") }end}
function M.list(t)for k,_ in pairs(methods)do table.insert(t,k)end;return 0 end
function M.call(m,a)local f=methods[m];if not f then return 1 end;return f.call(a or {}) end
return M
EOF

# ------------------------------
# 5) Core scripts (apply, schedule, pause, block/unblock, adguard_sync, health)
# ------------------------------
cat > "$WORKDIR/usr/share/parental/scripts/apply.sh" <<'EOF'
#!/bin/ash
set -e
nft(){ /usr/sbin/nft "$@"; }
logger -t parental-apply "Applying nftables rules"
nft list table inet parental >/dev/null 2>&1 || nft add table inet parental
nft list set inet parental kids_blocked >/dev/null 2>&1 || nft add set inet parental kids_blocked '{ type ether_addr; flags interval; }'
nft list chain inet fw4 forward | grep -q kids_blocked || \
  nft add rule inet fw4 forward ether saddr @inet:parental:kids_blocked drop
EOF

cat > "$WORKDIR/usr/share/parental/scripts/schedule_tick.sh" <<'EOF'
#!/bin/ash
logger -t parental-schedule "tick"
# Minimal tick for demo
EOF

cat > "$WORKDIR/usr/share/parental/scripts/pause.sh" <<'EOF'
#!/bin/ash
echo "pause stub"
EOF

cat > "$WORKDIR/usr/share/parental/scripts/block_now.sh" <<'EOF'
#!/bin/ash
NFT=/usr/sbin/nft
MAC="$1"
[ -n "$MAC" ] && $NFT add element inet parental kids_blocked { $MAC } 2>/dev/null
EOF

cat > "$WORKDIR/usr/share/parental/scripts/unblock_now.sh" <<'EOF'
#!/bin/ash
NFT=/usr/sbin/nft
MAC="$1"
TMP=$(mktemp)
$NFT list set inet parental kids_blocked | sed -n 's/.*elements = { \(.*\) }.*/\1/p' | tr ',' '\n' | grep -vi "$MAC" >"$TMP"
$NFT flush set inet parental kids_blocked
[ -s "$TMP" ] && $NFT add element inet parental kids_blocked { $(paste -sd, "$TMP") }
EOF

cat > "$WORKDIR/usr/share/parental/scripts/adguard_sync.sh" <<'EOF'
#!/bin/ash
UCI="/sbin/uci -q"
URL="$($UCI get parental.settings.adguard_url 2>/dev/null)"
TOKEN="$($UCI get parental.settings.adguard_token 2>/dev/null)"
[ -z "$URL" ] && exit 0
curl -sS -X POST -H "Authorization: Bearer $TOKEN" "$URL/control/clients" >/dev/null 2>&1 || logger -t parental "AdGuard sync failed"
EOF

cat > "$WORKDIR/usr/share/parental/scripts/health.sh" <<'EOF'
#!/bin/ash
echo "{"
echo "\"nft\": \"$([ -x /usr/sbin/nft ] && echo ok || echo missing)\","
echo "\"cron\": \"$([ -f /etc/crontabs/root ] && echo ok || echo missing)\","
echo "\"adguard\": \"$($(/usr/bin/curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/control/status 2>/dev/null || echo 000))\""
echo "}"
EOF

# ------------------------------
# 6) Web UI (simple static page)
# ------------------------------
cat > "$WORKDIR/www/parental-ui/index.html" <<'EOF'
<!DOCTYPE html>
<html><head>
<meta charset="utf-8"><title>Parental Suite</title>
<link rel="stylesheet" href="style.css">
</head><body>
<h1>Parental Suite v2</h1>
<div id="status">Loading...</div>
<table id="clients"><thead><tr><th>MAC</th><th>Action</th></tr></thead><tbody></tbody></table>
<script src="app.js"></script>
</body></html>
EOF

cat > "$WORKDIR/www/parental-ui/app.js" <<'EOF'
async function refresh(){
 const res=await fetch("/ubus",{method:"POST",headers:{"Content-Type":"application/json"},
  body:JSON.stringify({"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","parental","get_overview",{}]})});
 const js=await res.json();
 document.getElementById("status").innerText="Connected. "+(js.result? "Got data":"Error");
}
refresh();
setInterval(refresh,30000);
EOF

cat > "$WORKDIR/www/parental-ui/style.css" <<'EOF'
body{font-family:sans-serif;background:#f9f9f9;color:#222;padding:1em}
h1{color:#005}
table{border-collapse:collapse;width:100%}
td,th{border:1px solid #ccc;padding:4px}
EOF

# ------------------------------
# 7) Installer
# ------------------------------
cat > "$WORKDIR/install.sh" <<'EOF'
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
EOF

# ------------------------------
# 8) Zip it
# ------------------------------
(cd "$WORKDIR" && zip -r "$ZIPFILE" . >/dev/null)
echo "[+] Created $ZIPFILE"
echo "[+] Copy to router and run: scp $ZIPFILE root@192.168.1.1:/tmp/ && ssh root@192.168.1.1 'cd /tmp && unzip parental_suite_v2.zip && sh install.sh'"
