#!/bin/ash
NFT=/usr/sbin/nft
MAC="$1"
[ -n "$MAC" ] && $NFT add element inet parental kids_blocked { $MAC } 2>/dev/null
