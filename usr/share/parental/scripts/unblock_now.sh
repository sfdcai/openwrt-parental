#!/bin/ash
NFT=/usr/sbin/nft
MAC="$1"
TMP=$(mktemp)
$NFT list set inet parental kids_blocked | sed -n 's/.*elements = { \(.*\) }.*/\1/p' | tr ',' '\n' | grep -vi "$MAC" >"$TMP"
$NFT flush set inet parental kids_blocked
[ -s "$TMP" ] && $NFT add element inet parental kids_blocked { $(paste -sd, "$TMP") }
