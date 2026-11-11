#!/bin/sh
# Installs (or updates) Blink from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/jo-sip/blink/main/scripts/install.sh | sh
#
# What it does, in order: checks your macOS version, downloads Blink.zip from the latest release,
# checks its SHA-256, quits Blink if it's running, puts Blink.app in /Applications (or ~/Applications
# if you can't write there), and opens it. Nothing else is touched.
set -eu

REPO="jo-sip/blink"
URL="https://github.com/$REPO/releases/latest/download"
DEST="${BLINK_INSTALL_DIR:-/Applications}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Blink is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "Blink needs macOS 13 or later (you have $(sw_vers -productVersion))."

if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading the latest Blink…"
curl -fsSL "$URL/Blink.zip" -o "$TMP/Blink.zip" || fail "Couldn't download $URL/Blink.zip"
if curl -fsSL "$URL/Blink.zip.sha256" -o "$TMP/Blink.zip.sha256" 2>/dev/null; then
    expected=$(cut -d' ' -f1 "$TMP/Blink.zip.sha256")
    actual=$(shasum -a 256 "$TMP/Blink.zip" | cut -d' ' -f1)
    [ "$expected" = "$actual" ] || fail "Download checksum didn't match; try again."
fi

ditto -x -k "$TMP/Blink.zip" "$TMP/unzipped"
[ -d "$TMP/unzipped/Blink.app" ] || fail "The download didn't contain Blink.app."

if pgrep -x Blink >/dev/null 2>&1; then
    say "Quitting the running Blink…"
    pkill -x Blink || true
    sleep 1
fi

say "Installing to $DEST/Blink.app…"
rm -rf "$DEST/Blink.app"
ditto "$TMP/unzipped/Blink.app" "$DEST/Blink.app"
xattr -dr com.apple.quarantine "$DEST/Blink.app" 2>/dev/null || true

if [ -z "${BLINK_NO_OPEN:-}" ]; then
    open "$DEST/Blink.app"
fi

say "Done! Blink is in your menu bar (⚡). Press ⌘Space to open it."
echo "    If ⌘Space opens Spotlight instead: System Settings → Keyboard → Keyboard Shortcuts →"
echo "    Spotlight → untick “Show Spotlight search”. Or pick another shortcut in Blink's Settings."
