#!/bin/ash
set -e

nft(){ /usr/sbin/nft "$@"; }
UCI="/sbin/uci -q"
logger -t parental-apply "Applying nftables rules"

# Ensure parental table and sets/chains
nft list table inet parental >/dev/null 2>&1 || nft add table inet parental
nft list set inet parental kids_blocked >/dev/null 2>&1 || nft add set inet parental kids_blocked '{ type ether_addr; flags interval; }'

# Ensure usage chain (no base hook) and jump from fw4 forward
nft list chain inet parental usage >/dev/null 2>&1 || nft add chain inet parental usage
nft list chain inet fw4 forward | grep -q "jump inet parental usage" || nft add rule inet fw4 forward jump inet parental usage

# Ensure drop rule for blocked set
nft list chain inet fw4 forward | grep -q kids_blocked || nft add rule inet fw4 forward ether saddr @inet:parental:kids_blocked drop

# Ensure per-client counters and usage rules (idempotent)
MACS=$($UCI show parental | sed -n "s/^parental\\.@client\\[[0-9]\+\\]\\.mac='\([^']\+\)'.*/\1/p")
for MAC in $MACS; do
  NORM=$(echo "$MAC" | tr -d ':' | tr 'A-F' 'a-f')
  # add counter object if missing
  nft list counters inet parental 2>/dev/null | grep -q " c_${NORM}[[:space:]]" || nft add counter inet parental c_${NORM}
  # add usage rule if missing
  nft list chain inet parental usage 2>/dev/null | grep -iq "ether saddr \(\*\)\?${MAC}" || nft add rule inet parental usage ether saddr $MAC counter name c_${NORM}
done
