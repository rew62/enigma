#!/bin/bash
# start-lyrics-conky.sh — launches active-player.sh and conky together.
# Ctrl-C or kill cleanly stops both.
# v1 2026-07-04 @rew62

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
echo "BASEDIR=$BASEDIR"

TMP="/dev/shm/conky-lyrics"
mkdir -p "$TMP"

PIDFILE="$TMP/active-player.pid"
AP_PID=""
CONKY_PID=""

# ── Cleanup — kills both children on Ctrl-C / kill / normal exit ──────────
cleanup() {
    echo "Shutting down..."
    [ -n "$AP_PID" ]    && kill "$AP_PID"    2>/dev/null
    [ -n "$CONKY_PID" ] && kill "$CONKY_PID" 2>/dev/null
    rm -f "$PIDFILE"
    exit 0
}
trap cleanup INT TERM EXIT

# ── Kill any stale active-player instance ─────────────────────────────────
if [ -f "$PIDFILE" ]; then
    old_pid=$(< "$PIDFILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        echo "Stopping stale active-player (PID $old_pid)..."
        kill "$old_pid"
        sleep 0.3
    fi
    rm -f "$PIDFILE"
fi

# ── Start active-player.sh ────────────────────────────────────────────────
echo "Starting active-player.sh..."
"$BASEDIR/active-player.sh" &
AP_PID=$!
echo "$AP_PID" > "$PIDFILE"

sleep 0.5

# ── Start conky ───────────────────────────────────────────────────────────
echo "Starting conky..."
cd "$BASEDIR" || exit
# Wayland: uncomment to force conky onto its X11/XWayland backend
# (native Wayland backend lacks the ARGB/click-through support this widget
# needs); no-op on a real X11 session.
# env WAYLAND_DISPLAY= XDG_SESSION_TYPE=x11 conky -c "$BASEDIR/lyrics.rc" &
conky -c "$BASEDIR/lyrics.rc" &
CONKY_PID=$!

echo "Running.  active-player PID: $AP_PID   conky PID: $CONKY_PID"
echo "Ctrl-C to stop both."

# Block here so the trap fires on Ctrl-C
wait $CONKY_PID
