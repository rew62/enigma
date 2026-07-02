#!/bin/bash
# Loads all Music Conky/Lua Scripts
# 
# v1 2026-07-04 @rew62
cd "$(dirname "$0")" || exit

start() {
    # Wayland: uncomment to force conky onto its X11/XWayland backend
    # (native Wayland backend lacks the ARGB/click-through support these
    # widgets rely on); no-op on a real X11 session.
    # setsid env WAYLAND_DISPLAY= XDG_SESSION_TYPE=x11 conky -c nowplaying.rc > /dev/null 2>&1 &
    # setsid env WAYLAND_DISPLAY= XDG_SESSION_TYPE=x11 conky -c eq.rc > /dev/null 2>&1 &
    setsid conky -c nowplaying.rc > /dev/null 2>&1 &
    setsid conky -c eq.rc > /dev/null 2>&1 &
    setsid bash start-lyrics-conky.sh > /dev/null 2>&1 &
}

stop() {
    # bracket around the first letter keeps pkill -f from matching its own
    # invoking shell's command line (which contains the literal pattern)
    pkill -f "[n]owplaying.rc"
    pkill -f "[e]q.rc"
    # lyrics manages its own cleanup via TERM signal
    pkill -f "[s]tart-lyrics-conky.sh"
    pkill -f "[a]ctive-player.sh"
    pkill -f "[l]yrics.rc"
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 2; start ;;
    *)       echo "Usage: $0 {start|stop|restart}" ; exit 1 ;;
esac

exit 0
