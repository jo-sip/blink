#!/bin/sh
# Regenerates docs/screenshots/*.png from made-up demo data (fake Messages database, sample clipboard,
# sample pins), over a colourful backdrop. Your own config, messages and clipboard are never read.
# Each scene briefly opens the launcher on screen; don't type while it runs.
set -e
cd "$(dirname "$0")/.."
OUT=docs/screenshots
mkdir -p "$OUT"
scripts/build-app.sh >/dev/null
BIN=build/Blink.app/Contents/MacOS/Blink
DEMO="$(mktemp -d)"
trap 'rm -rf "$DEMO"' EXIT
python3 scripts/demo/make-demo-data.py "$DEMO" >/dev/null
export BLINK_CONFIG_DIR="$DEMO/config" BLINK_DATA_DIR="$DEMO/data" BLINK_MESSAGES_DB="$DEMO/chat.db" \
       BLINK_FAKE_CONTACTS="$DEMO/contacts.json"

windows() { swift scripts/demo/windows.swift 2>/dev/null; }

# scene <name> <--show argument> [seconds]
scene() {
    BLINK_BACKDROP=1 "$BIN" --show "$2" >/dev/null 2>&1 &
    pid=$!
    sleep "${3:-2.5}"
    # Crop: the backdrop's width, from its top to just below the launcher.
    # The launcher window is 776 wide (720 of glass plus a clear margin); the backdrop is 860.
    rect=$(windows | awk '$4==776 {px=$2; py=$3; ph=$5} $4==860 {bx=$2; by=$3; bw=$4}
        END { if (bw) printf "%d,%d,%d,%d", bx, by, bw, (py + ph + 28) - by }')
    if [ -n "$rect" ]; then screencapture -x -R"$rect" "$OUT/$1.png" && echo "  $1.png"; else echo "  $1: window not found"; fi
    kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
    sleep 0.4
}

echo "Capturing into $OUT"
scene hero ""
scene messages "mode:m"
scene reply "demo-live" 3.5
scene search "pho"
scene calculator "128 * 3 + 7^2"
scene clipboard "mode:v"

"$BIN" --show "settings:codes" >/dev/null 2>&1 &
pid=$!
sleep 2.5
id=$(windows | awk '$4>=700 && $4!=776 && $4!=860 {print $1; exit}')
[ -n "$id" ] && screencapture -x -l "$id" "$OUT/settings.png" && echo "  settings.png"
kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
