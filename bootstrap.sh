#!/bin/sh
set -eu

log() {
  printf '[bootstrap] %s\n' "$*"
}

fail() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found. Install it with opkg (e.g. opkg update && opkg install $1)."
}

for cmd in curl unzip sh mktemp; do
  require_cmd "$cmd"
done

REPO="${REPO:-sfdcai/openwrt-parental}"
ARCHIVE_NAME="${ARCHIVE_NAME:-parental_suite_v2.zip}"
VERSION="${VERSION:-latest}"

if [ -n "${PKG_URL:-}" ]; then
  DOWNLOAD_URL="$PKG_URL"
else
  case "$VERSION" in
    latest)
      DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$ARCHIVE_NAME"
      ;;
    *)
      DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$ARCHIVE_NAME"
      ;;
  esac
fi

BASE_DIR="${TMPDIR:-/tmp}"
mkdir -p "$BASE_DIR"
WORKDIR="$(mktemp -d "$BASE_DIR/parental_suite_v2.XXXXXX")"
cleanup() {
  if [ "${KEEP_FILES:-0}" != "1" ] && [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT INT TERM

cd "$WORKDIR"
log "Downloading package from $DOWNLOAD_URL"
curl -fL "$DOWNLOAD_URL" -o "$ARCHIVE_NAME.part"
mv "$ARCHIVE_NAME.part" "$ARCHIVE_NAME"

log "Unpacking archive"
unzip -o "$ARCHIVE_NAME" >/dev/null

if [ ! -f install.sh ]; then
  fail "install.sh not found after extracting archive."
fi

log "Running installer"
sh install.sh

if [ "${KEEP_FILES:-0}" = "1" ]; then
  log "Installer finished. Files are kept in $WORKDIR"
else
  log "Installer finished"
fi
