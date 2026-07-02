#!/bin/bash
# get-lyrics.sh — fetches synced lyrics from local cache, NetEase, or LRCLIB.
# All temp files live in /dev/shm to avoid disk I/O.
# v1 2026-07-04 @rew62

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
TMP="/dev/shm/conky-lyrics"
mkdir -p "$TMP"

txtfile="$TMP/lyrics.txt"
outfile="$TMP/lyrics.out"
chkfile="$TMP/lyrics.chk"
jqfile="$TMP/lyrics.jq"
inst_helper="$BASEDIR/instrumental_lrclib.sh"

LOCAL_LYRICS_DIR="$HOME/lyrics"

# wget timeout (seconds) — prevents the startup hang when network is slow/unavailable
WGET_TIMEOUT=10
WGET_TRIES=1

sendmsg() {
    printf '\n${color 888888}Get-lyrics: ${color FF0000} %s' "$1" > "$outfile"
    printf 'Get-lyrics: %s\n' "$1" >&2
}

arg1="$1"
[ -z "$arg1" ] && exit 0
save_lyrics="$2"   # "--save" for local files, empty for streams

artist="${arg1%%|*}"; rest="${arg1#*|}"; title="${rest%%|*}"; album="${rest#*|}"

current="$artist|$title|$album"
last_checked=""
[ -f "$chkfile" ] && last_checked=$(cat "$chkfile")

if [ "$current" != "$last_checked" ]; then
    echo "$current" > "$chkfile"
fi

###################################################################
# Helper: save to local cache
###################################################################
save_to_cache() {
    [ "$save_lyrics" = "--save" ] || return
    [ -d "$LOCAL_LYRICS_DIR" ] || return
    local cache_file="$LOCAL_LYRICS_DIR/${artist} - ${title}.lrc"
    cp "$txtfile" "$cache_file" 2>/dev/null
}

###################################################################
# 1. Local cache
###################################################################
search_local() {
    [ -d "$LOCAL_LYRICS_DIR" ] || return 1

    local local_file="$LOCAL_LYRICS_DIR/${artist} - ${title}.lrc"
    if [ -f "$local_file" ]; then
        cp "$local_file" "$txtfile"
        sendmsg "Lyrics from local cache"
        return 0
    fi

    local found_file
    # Case-insensitive glob via find — try artist+title, then title alone
    found_file=$(find "$LOCAL_LYRICS_DIR" -type f -name "*.lrc" \
        -iname "*${artist}*${title}*" 2>/dev/null | head -n1)
    if [ -z "$found_file" ]; then
        # Title-only fallback: a bare title substring can match an unrelated
        # artist whose name happens to contain that word (e.g. "Atomic" also
        # matching "Atomic Kitten"). Require the requested artist to also
        # appear (normalized, loosely) in the matched filename.
        local candidate norm_base norm_artist
        candidate=$(find "$LOCAL_LYRICS_DIR" -type f -name "*.lrc" \
            -iname "*${title}*" 2>/dev/null | head -n1)
        if [ -n "$candidate" ]; then
            norm_base=$(tr '[:upper:]' '[:lower:]' <<<"$(basename "$candidate")" | tr -cd 'a-z0-9')
            norm_artist=$(tr '[:upper:]' '[:lower:]' <<<"$artist" | tr -cd 'a-z0-9')
            [[ -n "$norm_artist" && "$norm_base" == *"$norm_artist"* ]] && found_file="$candidate"
        fi
    fi

    if [ -n "$found_file" ]; then
        cp "$found_file" "$txtfile"
        sendmsg "Local cache (fuzzy: $(basename "$found_file"))"
        return 0
    fi

    return 1
}

###################################################################
# 3. LRCLIB (fallback -- slower to respond than NetEase in practice,
# but an exact artist/track lookup rather than fuzzy full-text search;
# only tried when NetEase comes up empty or fails its mismatch guard)
###################################################################
fetch_lrclib() {
    local urlartist urltitle urlalbum
    urlartist=$(sed 's/[][{}() _~,]/+/g' <<<"$artist")
    urltitle=$(sed 's/[][{}() _~,]/+/g' <<<"$title")
    urlalbum=$(sed 's/[][{}() _~,]/+/g' <<<"$album")

    local url="https://lrclib.net/api/get?artist_name=${urlartist}&track_name=${urltitle}&album_name=${urlalbum}"

    wget -q --timeout="$WGET_TIMEOUT" --tries="$WGET_TRIES" -O "$jqfile" "$url" || return 1

    local lyrics
    lyrics=$(jq -r '.syncedLyrics // empty' "$jqfile")

    if [ -n "$lyrics" ]; then
        printf 'Artist: %s\nTitle : %s\nAlbum : %s\n\n' "$artist" "$title" "$album" > "$txtfile"
        printf '%s\n' "$lyrics" >> "$txtfile"
        sendmsg "Lyrics via LRCLIB"
        save_to_cache
        return 0
    fi

    # Check instrumental via helper
    if [ -x "$inst_helper" ] && "$inst_helper" "$jqfile"; then
        printf 'Artist: %s\nTitle : %s\nAlbum : %s\n\n' "$artist" "$title" "$album" > "$txtfile"
        printf '[00:00.00]Instrumental\n' >> "$txtfile"
        sendmsg "Instrumental (LRCLIB)"
        return 0
    fi

    return 1
}

###################################################################
# 2. NetEase (faster than LRCLIB; cloudsearch is fuzzy full-text and
# can match the wrong song, so a mismatch guard below rejects a bad hit
# and falls through to LRCLIB instead of serving wrong lyrics)
###################################################################
fetch_netease() {
    local query
    query=$(printf '%s %s' "$artist" "$title" | sed 's/ /%20/g')
    local search_url="https://music.163.com/api/cloudsearch/pc?type=1&limit=1&s=${query}"

    wget -q --timeout="$WGET_TIMEOUT" --tries="$WGET_TRIES" -O "$jqfile" "$search_url" || return 1

    local song_id song_name song_artists
    song_id=$(jq -r '.result.songs[0].id // empty' "$jqfile") || return 1
    [ -z "$song_id" ] && return 1
    song_name=$(jq -r '.result.songs[0].name // empty' "$jqfile")
    song_artists=$(jq -r '(.result.songs[0].ar // []) | map(.name) | join(" ")' "$jqfile")

    # Reject a fuzzy mismatch: cloudsearch is full-text and can return an
    # unrelated song (e.g. a cover, karaoke version, or same-artist track).
    # Normalize (lowercase, strip everything but letters/digits) and require
    # the requested title to appear in the returned name (or vice versa,
    # to tolerate suffixes like "(Remastered)"), plus the requested artist
    # to appear somewhere in the returned artist list.
    local norm_title norm_song_name norm_artist norm_song_artists
    norm_title=$(tr '[:upper:]' '[:lower:]' <<<"$title" | tr -cd 'a-z0-9')
    norm_song_name=$(tr '[:upper:]' '[:lower:]' <<<"$song_name" | tr -cd 'a-z0-9')
    norm_artist=$(tr '[:upper:]' '[:lower:]' <<<"$artist" | tr -cd 'a-z0-9')
    norm_song_artists=$(tr '[:upper:]' '[:lower:]' <<<"$song_artists" | tr -cd 'a-z0-9')

    [[ -n "$norm_song_name" && ( "$norm_song_name" == *"$norm_title"* || "$norm_title" == *"$norm_song_name"* ) ]] || return 1
    [[ -n "$norm_song_artists" && "$norm_song_artists" == *"$norm_artist"* ]] || return 1

    local lyric_url="https://music.163.com/api/song/lyric?id=${song_id}&lv=1&tv=0"
    wget -q --timeout="$WGET_TIMEOUT" --tries="$WGET_TRIES" -O "$jqfile" "$lyric_url" || return 1

    local lyrics
    lyrics=$(jq -r '.lrc.lyric // empty' "$jqfile")
    [ -z "$lyrics" ] && return 1

    printf 'Artist: %s\nTitle : %s\nAlbum : %s\n\n' "$artist" "$title" "$album" > "$txtfile"
    printf '%s\n' "$lyrics" >> "$txtfile"
    sendmsg "Lyrics via NetEase"
    save_to_cache
    return 0
}

###################################################################
# MAIN
###################################################################
search_local || fetch_netease || fetch_lrclib || sendmsg "No lyrics found"
