#!/bin/sh
set -eu

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '%s\n' "[-] Missing required command: $1" >&2
    exit 1
  }
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
OUTPUT_NAME="${1:-parental_suite_v2}"
[ "${2:-}" = "" ] || { printf 'Usage: %s [output-name]\n' "$0" >&2; exit 1; }

require_cmd zip
require_cmd mktemp
require_cmd cp

STAGING=$(mktemp -d "$SCRIPT_DIR/.pkg.$OUTPUT_NAME.XXXXXX")
PAYLOAD_DIR="$STAGING/$OUTPUT_NAME"
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT INT TERM

mkdir -p "$PAYLOAD_DIR"

copy_item() {
  item="$1"
  if [ -e "$SCRIPT_DIR/$item" ]; then
    cp -a "$SCRIPT_DIR/$item" "$PAYLOAD_DIR/"
  fi
}

for item in etc usr www install.sh Makefile CHANGELOG.md README.md; do
  copy_item "$item"
done

ZIP_PATH="$SCRIPT_DIR/$OUTPUT_NAME.zip"
rm -f "$ZIP_PATH"

printf '[+] Packaging files into %s\n' "$ZIP_PATH"
(
  cd "$STAGING"
  zip -rq "$ZIP_PATH" "$OUTPUT_NAME"
)

printf '[+] Created %s\n' "$ZIP_PATH"
printf '[+] Upload to the router and install:\n'
printf '    scp %s root@<router-ip>:/tmp/\n' "$ZIP_PATH"
printf '    ssh root@<router-ip> "cd /tmp && unzip -o %s && sh install.sh"\n' "$(basename "$ZIP_PATH")"
printf '[+] Or run the bootstrap script: curl -fsSL https://raw.githubusercontent.com/sfdcai/openwrt-parental/main/bootstrap.sh | sh\n'
