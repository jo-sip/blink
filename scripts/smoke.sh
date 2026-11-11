#!/bin/sh
# Smoke test for the parts unit tests can't reach: the real binary, real app list and the launcher window.
# Uses throwaway config/data folders, so your settings, pins and usage history are never touched.
# The UI step briefly opens the launcher on screen and reads Messages read-only.
#   scripts/smoke.sh          # CLI checks + UI redraw check
#   scripts/smoke.sh --no-ui  # CLI checks only
set -u
cd "$(dirname "$0")/.."
export BLINK_CONFIG_DIR="$(mktemp -d)" BLINK_DATA_DIR="$(mktemp -d)"
trap 'rm -rf "$BLINK_CONFIG_DIR" "$BLINK_DATA_DIR"' EXIT
fails=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }

swift build -c release >/dev/null 2>&1 || { echo "build failed"; exit 1; }
B=.build/release/Blink
top() { "$B" --query "$1" 2>/dev/null | head -1 | cut -f2; }

echo "Search results"
[ "$(top '12*(3+4)/2')" = "42" ] && pass "calculator" || fail "calculator: got '$(top '12*(3+4)/2')'"
[ "$(top 'github.com/x')" = "Open https://github.com/x" ] && pass "URL" || fail "URL"
[ "$(top 'g cats')" = "Search Google for “cats”" ] && pass "web search keyword" || fail "web search keyword"
[ "$(top 'm')" = "Messages" ] && pass "short code m → Messages" || fail "short code m"
[ "$(top 'v')" = "Clipboard" ] && pass "short code v → Clipboard" || fail "short code v"
[ "$(top 'dow')" = "Downloads" ] && pass "places: Downloads" || fail "places: got '$(top dow)'"
[ "$(top 'safari')" = "Safari" ] && pass "apps: Safari" || fail "apps: got '$(top safari)'"
ms=$("$B" --query chr --bench 2>&1 | sed -n 's/bench: \([0-9.]*\) µs.*/\1/p')
[ -n "$ms" ] && [ "$(echo "$ms < 1000" | bc)" = 1 ] && pass "app search ${ms}µs per keystroke" || fail "app search slow: ${ms}µs"
[ ! -f "$BLINK_DATA_DIR/pins.json" ] && pass "no pins written" || fail "pins written during CLI run"

if [ "${1:-}" != "--no-ui" ]; then
    echo "Launcher window (one draw per keystroke)"
    log=$(BLINK_DEBUG=1 sh -c "'$B' --show 'type:m,me,mes,mes ,mes a,chr' 2>&1 & pid=\$!; sleep 4; kill \$pid" 2>&1)
    for q in "m" "me" "mes" "mes " "mes a" "chr"; do
        n=$(printf '%s\n' "$log" | grep -F "[$q] draw" | grep -vc "skip")
        [ "$n" -le 1 ] && pass "'$q' drew $n time(s)" || fail "'$q' drew $n times (flicker)"
    done
fi

echo
[ "$fails" -eq 0 ] && echo "All smoke checks passed" || echo "$fails smoke check(s) failed"
exit "$fails"
