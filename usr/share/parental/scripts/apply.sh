#!/bin/ash
set -e
nft(){ /usr/sbin/nft "$@"; }
logger -t parental-apply "Applying nftables rules"
nft list table inet parental >/dev/null 2>&1 || nft add table inet parental
nft list set inet parental kids_blocked >/dev/null 2>&1 || nft add set inet parental kids_blocked '{ type ether_addr; flags interval; }'
nft list chain inet fw4 forward | grep -q kids_blocked || \
  nft add rule inet fw4 forward ether saddr @inet:parental:kids_blocked drop
