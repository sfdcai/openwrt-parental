#!/bin/sh
set -eu

log() {
  printf '[bootstrap] %s\n' "$*"
}

fail() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

OPKG_BIN="${OPKG_BIN:-$(command -v opkg 2>/dev/null || true)}"
OPKG_UPDATED=0

ensure_pkg() {
  pkg="$1"
  [ -n "$OPKG_BIN" ] || return 1
  if "$OPKG_BIN" list-installed "$pkg" >/dev/null 2>&1; then
    return 0
  fi
  if [ "${BOOTSTRAP_SKIP_OPKG_UPDATE:-0}" != "1" ] && [ $OPKG_UPDATED -eq 0 ]; then
    log "Updating opkg package list"
    if "$OPKG_BIN" update >/dev/null 2>&1; then
      OPKG_UPDATED=1
    else
      log "opkg update failed, continuing with install attempts"
      OPKG_UPDATED=1
    fi
  fi
  log "Installing package $pkg"
  "$OPKG_BIN" install "$pkg" >/dev/null 2>&1 || "$OPKG_BIN" install "$pkg" || return 1
}

ensure_cmd() {
  cmd="$1"
  shift
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  for pkg in "$@"; do
    if ensure_pkg "$pkg"; then
      command -v "$cmd" >/dev/null 2>&1 && return 0
    fi
  done
  [ $# -gt 0 ] && fail "Required command '$cmd' not found; attempted to install package(s): $*" || fail "Required command '$cmd' not found."
}

ensure_cmd sh
ensure_cmd mktemp busybox coreutils-mktemp
ensure_cmd curl curl
ensure_cmd unzip unzip busybox

REPO="${REPO:-sfdcai/openwrt-parental}"
ARCHIVE_NAME="${ARCHIVE_NAME:-parental_suite_v2.zip}"
VERSION="${VERSION:-latest}"

download() {
  url="$1"
  outfile="$2"
  log "Downloading package from $url"
  if curl -fL "$url" -o "$outfile.part"; then
    mv "$outfile.part" "$outfile"
    return 0
  fi

  rm -f "$outfile.part"
  return 1
}

if [ -n "${PKG_URL:-}" ]; then
  DOWNLOAD_URL="$PKG_URL"
  FALLBACK_URL=""
else
  case "$VERSION" in
    latest)
      DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$ARCHIVE_NAME"
      FALLBACK_URL="https://github.com/$REPO/archive/refs/heads/main.zip"
      ;;
    *)
      DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$ARCHIVE_NAME"
      FALLBACK_URL="https://github.com/$REPO/archive/refs/tags/$VERSION.zip"
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
ARCHIVE_FILE="$ARCHIVE_NAME"

if ! download "$DOWNLOAD_URL" "$ARCHIVE_FILE"; then
  if [ -n "$FALLBACK_URL" ]; then
    ARCHIVE_NAME="$(basename "$FALLBACK_URL")"
    [ -n "$ARCHIVE_NAME" ] || ARCHIVE_NAME="package.zip"
    ARCHIVE_FILE="$ARCHIVE_NAME"
    log "Primary download failed, trying fallback archive"
    download "$FALLBACK_URL" "$ARCHIVE_FILE" || fail "Failed to download package from both primary and fallback URLs."
  else
    fail "Failed to download package from $DOWNLOAD_URL"
  fi
fi

log "Unpacking archive"
unzip -o "$ARCHIVE_FILE" >/dev/null

INSTALLER_PATH=""
if [ -f install.sh ]; then
  INSTALLER_PATH="./install.sh"
else
  INSTALLER_PATH="$(find . -maxdepth 2 -type f -name install.sh | head -n1 || true)"
fi

if [ -z "$INSTALLER_PATH" ]; then
  fail "install.sh not found after extracting archive."
fi

INSTALLER_DIR="$(dirname "$INSTALLER_PATH")"

log "Running installer from $INSTALLER_DIR/install.sh"
(cd "$INSTALLER_DIR" && sh ./install.sh)

if [ "${KEEP_FILES:-0}" = "1" ]; then
  log "Installer finished. Files are kept in $WORKDIR"
else
  log "Installer finished"
fi
