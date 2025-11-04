#!/bin/sh
# Collect diagnostics for Parental Suite

set -eu

print_section() {
  printf '\n==== %s ====' "$1"
  printf '\n'
}

print_section "Environment"
if command -v date >/dev/null 2>&1; then
  date
fi
uname -a 2>/dev/null || true

print_section "Packages"
if command -v opkg >/dev/null 2>&1; then
  opkg list-installed | grep -E 'parental|lua|json|uhttpd' || true
else
  echo "opkg not present"
fi

print_section "UCI parental"
uci -q show parental || echo "uci show parental failed"

print_section "RPCD ACL"
ls -l /usr/share/rpcd/acl.d 2>/dev/null || true

print_section "RPCD parent object"
if command -v ubus >/dev/null 2>&1; then
  ubus list parental || echo "parental object missing"
  ubus call parental health 2>/dev/null || echo "ubus health call failed"
else
  echo "ubus not present"
fi

print_section "Service status"
if [ -x /etc/init.d/parental ]; then
  /etc/init.d/parental status 2>&1 || true
else
  echo "parental init script missing"
fi
if [ -x /etc/init.d/uhttpd ]; then
  /etc/init.d/uhttpd status 2>&1 || true
fi

print_section "Processes"
ps w 2>/dev/null | grep -E 'rpcd|uhttpd|parental' | grep -v grep || true

print_section "Sockets"
if command -v netstat >/dev/null 2>&1; then
  netstat -lnp 2>/dev/null | grep -E '8088|uhttpd' || true
fi

print_section "Logs"
if command -v logread >/dev/null 2>&1; then
  logread | tail -n 50
else
  echo "logread not available"
fi

exit 0
