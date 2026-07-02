#!/bin/bash
# Detect instrumental using LRCLIB response ONLY
# v1 2026-07-04 @rew62

jqfile="$1"

# Safety
[ -z "$jqfile" ] || [ ! -f "$jqfile" ] && exit 1

# LRCLIB explicit instrumental detection
inst=$(jq -r '
    (.instrumental // false) or
    (
      (.syncedLyrics == null or .syncedLyrics == "") and
      (.plainLyrics == null or .plainLyrics == "")
    )
' "$jqfile" 2>/dev/null)

[ "$inst" = "true" ] && exit 0
exit 1

