#!/bin/bash
# position-clean.sh - Revert window.lua position saves in conky rc files.
# Uncomments the original alignment/gap_x/gap_y lines and removes the 4
# lines inserted by Ctrl+left-click (the annotation comment + 3 new values).
#
# Usage:
#   position-clean.sh <path/to/config.rc>   -- revert a single file
#   position-clean.sh all                   -- recurse from repo root
#
# v1 2026-07-04 @rew62

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

clean_file() {
    local file="$1"

    # Skip if window.lua has never written to this file
    grep -q "^[[:space:]]*--[[:space:]]*alignment[[:space:]]*=" "$file" 2>/dev/null || return 0

    echo "Reverting: $file"

    local tmp
    tmp=$(mktemp) || { echo "mktemp failed"; return 1; }

    awk '
    BEGIN { skip = 0 }

    # Uncomment the original alignment line
    /^[[:space:]]*--[[:space:]]*alignment[[:space:]]*=/ {
        match($0, /^[[:space:]]*/)
        indent = substr($0, 1, RLENGTH)
        rest   = substr($0, RLENGTH + 1)
        sub(/^--[[:space:]]*/, "", rest)
        print indent rest
        next
    }

    # Uncomment the original gap_x line
    /^[[:space:]]*--[[:space:]]*gap_x[[:space:]]*=/ {
        match($0, /^[[:space:]]*/)
        indent = substr($0, 1, RLENGTH)
        rest   = substr($0, RLENGTH + 1)
        sub(/^--[[:space:]]*/, "", rest)
        print indent rest
        next
    }

    # Uncomment the original gap_y line, then skip the 4 inserted lines that follow:
    #   -- Position moved via Alt+drag, saved via Ctrl+left-click
    #   alignment = '"'"'top_left'"'"',
    #   gap_x = NNN,
    #   gap_y = NNN,
    /^[[:space:]]*--[[:space:]]*gap_y[[:space:]]*=/ {
        match($0, /^[[:space:]]*/)
        indent = substr($0, 1, RLENGTH)
        rest   = substr($0, RLENGTH + 1)
        sub(/^--[[:space:]]*/, "", rest)
        print indent rest
        skip = 4
        next
    }

    skip > 0 { skip--; next }

    { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; echo "  FAILED: $file"; }
}

# ── Argument handling ──────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
    echo "Usage: $(basename "$0") <config.rc>"
    echo "       $(basename "$0") all"
    exit 1
fi

if [ "$1" = "all" ]; then
    echo "Scanning $REPO_DIR ..."
    found=0
    while IFS= read -r f; do
        clean_file "$f"
        found=$((found + 1))
    done < <(find "$REPO_DIR" -name "*.rc" -type f | sort)
    echo "Done. Checked $found rc files."
else
    if [ ! -f "$1" ]; then
        echo "Error: file not found: $1"
        exit 1
    fi
    clean_file "$1"
    echo "Done."
fi
