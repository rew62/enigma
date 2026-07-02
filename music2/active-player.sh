#!/bin/bash
# active-player.sh — event-driven lyric fetcher via playerctl --follow.
# Zero polling cost; wakes only on DBus property changes (song change, play/pause).
# v1 2026-07-04 @rew62

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
TMP="/dev/shm/conky-lyrics"
mkdir -p "$TMP"

outfile="$TMP/lyrics.out"
pidfile="$TMP/active-player.pid"
echo $$ > "$pidfile"

cleanup() { pkill -P $$ 2>/dev/null; rm -f "$pidfile"; exit 0; }
trap cleanup INT TERM EXIT

sendmsg() {
    printf '\n${color 888888}Active-player: ${color FF0000} %s' "$1" > "$outfile"
}

FMT='{{status}}|{{playerName}}|{{xesam:artist}}|{{xesam:title}}|{{xesam:album}}|{{mpris:artUrl}}|{{xesam:url}}'

last_song=""

handle_line() {
    local line="$1"
    local status pname artist title album art_url track_url rest

    status="${line%%|*}";  rest="${line#*|}"
    pname="${rest%%|*}";   rest="${rest#*|}"
    artist="${rest%%|*}";  rest="${rest#*|}"
    title="${rest%%|*}";   rest="${rest#*|}"
    album="${rest%%|*}";   rest="${rest#*|}"
    art_url="${rest%%|*}"; track_url="${rest#*|}"

    if [ "$status" = "Playing" ]; then
        echo -n "$pname" > "$TMP/player.running"

        # Stream split: mirrors nowplaying.lua.
        # For streams using "Artist - Title" in the title field, no " - " means
        # it's a commercial or station ID — skip entirely.
        if [ -z "$artist" ] || [ "$artist" = "null" ]; then
            if [[ "$title" == *" - "* ]]; then
                artist="${title%% - *}"; title="${title#* - }"
            elif [[ "$track_url" == http://* || "$track_url" == https://* ]]; then
                return
            fi
        elif [ -z "$art_url" ]; then
            if [[ "$title" == *" - "* ]]; then
                local ta="${title%% - *}"
                if [ "$ta" != "$artist" ]; then
                    artist="$ta"; title="${title#* - }"
                fi
            elif [[ "$track_url" == http://* || "$track_url" == https://* ]]; then
                return
            fi
        fi

        # Stream URLs (http/https) never provide a real album — the album field
        # is just the stream domain, which breaks the LRCLIB album_name lookup.
        local save_flag=""
        if [[ "$track_url" == http://* ]] || [[ "$track_url" == https://* ]]; then
            album=""
            echo "stream" > "$TMP/track_type"
        else
            [[ "$track_url" == file://* ]] && save_flag="--save"
            rm -f "$TMP/track_type"
        fi

        local current="$artist|$title|$album"

        if [ "$current" != "$last_song" ]; then
            last_song="$current"
            # For streams, record wall-clock start time — playerctl position is
            # cumulative stream time, not position within the current track.
            [[ "$track_url" == http://* || "$track_url" == https://* ]] && date +%s.%3N > "$TMP/song_start"
            > "$TMP/lyrics.txt"
            > "$TMP/lyrics.out"
            rm -f "$TMP/lyrics.parsed"
            sendmsg "Fetching: $artist - $title"
            "$BASEDIR/get-lyrics.sh" "$current" $save_flag
        fi
    else
        if [ -n "$last_song" ]; then
            > "$outfile"
            > "$TMP/player.running"
            last_song=""
        fi
    fi
}

# Bootstrap: --follow only fires on changes, so emit current state once at startup
line=$(playerctl metadata --format "$FMT" 2>/dev/null)
[ -n "$line" ] && handle_line "$line"

# Event loop — restarts if --follow exits (all players disconnected)
while true; do
    while IFS= read -r line; do
        handle_line "$line"
    done < <(playerctl --follow --player "%any" metadata --format "$FMT" 2>/dev/null)

    # --follow exited — clear state and wait for a player to appear
    > "$outfile"
    > "$TMP/player.running"
    last_song=""
    sleep 2
done
