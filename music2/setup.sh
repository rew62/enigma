#!/bin/bash
# setup.sh — dependency check and first-time setup for lyrics-conky.
# Run once on a new machine before starting.
# v1 2026-07-04 @rew62

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_LYRICS_DIR="$HOME/lyrics"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
NC='\033[0m'

ok()   { printf "${GRN}  [OK]${NC}  %s\n" "$1"; }
warn() { printf "${YLW}  [WARN]${NC} %s\n" "$1"; }
fail() { printf "${RED}  [MISSING]${NC} %s\n" "$1"; MISSING=1; }

MISSING=0

#echo ""
#echo "=== Lyrics-Conky Setup Check ==="
#echo ""

# ── Required binaries ─────────────────────────────────────────────────────
echo "--- Required packages ---"

check_bin() {
    local bin="$1" pkg="$2"
    if command -v "$bin" &>/dev/null; then
        ok "$bin  ($(command -v $bin))"
    else
        fail "$bin not found — install with: sudo apt install $pkg"
    fi
}

check_bin conky    conky
check_bin playerctl playerctl
check_bin gawk     gawk
check_bin jq       jq
check_bin wget     wget

echo ""

# ── Verify awk resolves to gawk (not mawk) ────────────────────────────────
echo "--- awk version ---"
AWK_VERSION=$(awk --version 2>&1 | head -n1)
if echo "$AWK_VERSION" | grep -qi "gnu awk"; then
    ok "awk → gawk  ($AWK_VERSION)"
else
    warn "awk does not point to gawk: $AWK_VERSION"
    warn "Scripts call 'awk' directly — run: sudo apt install gawk"
    warn "After install, awk symlink should update automatically."
    warn "Verify with: awk --version | head -1"
    MISSING=1
fi

echo ""

# ── Local lyrics directory ─────────────────────────────────────────────────
echo "--- Local lyrics cache ---"
if [ -d "$LOCAL_LYRICS_DIR" ]; then
    COUNT=$(find "$LOCAL_LYRICS_DIR" -name "*.lrc" 2>/dev/null | wc -l)
    ok "$LOCAL_LYRICS_DIR exists  ($COUNT .lrc files cached)"
else
    warn "$LOCAL_LYRICS_DIR does not exist — creating it..."
    mkdir -p "$LOCAL_LYRICS_DIR" && ok "Created $LOCAL_LYRICS_DIR" || fail "Could not create $LOCAL_LYRICS_DIR"
fi

echo ""

# ── /dev/shm writable ─────────────────────────────────────────────────────
echo "--- /dev/shm ---"
if mkdir -p /dev/shm/conky-lyrics 2>/dev/null && touch /dev/shm/conky-lyrics/.test 2>/dev/null; then
    rm -f /dev/shm/conky-lyrics/.test
    ok "/dev/shm/conky-lyrics is writable"
else
    fail "/dev/shm/conky-lyrics is not writable — tmpfs may not be mounted"
fi

echo ""

# ── Script permissions ────────────────────────────────────────────────────
echo "--- Script permissions ---"
for script in active-player.sh get-lyrics.sh show-lyric start-lyrics-conky.sh; do
    f="$BASEDIR/$script"
    if [ ! -f "$f" ]; then
        fail "$script not found in $BASEDIR"
    elif [ ! -x "$f" ]; then
        warn "$script is not executable — fixing..."
        chmod +x "$f" && ok "$script  (fixed)" || fail "Could not chmod $script"
    else
        ok "$script"
    fi
done

# Check optional instrumental helper
if [ -f "$BASEDIR/instrumental_lrclib.sh" ]; then
    if [ ! -x "$BASEDIR/instrumental_lrclib.sh" ]; then
        chmod +x "$BASEDIR/instrumental_lrclib.sh"
        ok "instrumental_lrclib.sh  (fixed permissions)"
    else
        ok "instrumental_lrclib.sh"
    fi
else
    warn "instrumental_lrclib.sh not found (optional — instrumental detection disabled)"
fi

echo ""

# ── show-lyric.ini present ────────────────────────────────────────────────
echo "--- Config files ---"
if [ -f "$BASEDIR/show-lyric.ini" ]; then
    ok "show-lyric.ini"
else
    fail "show-lyric.ini not found — lyrics display styling will not work"
fi

echo ""

# ── playerctl can see a player (non-fatal, informational) ─────────────────
echo "--- playerctl ---"
PLAYERS=$(playerctl -l 2>/dev/null)
if [ -n "$PLAYERS" ]; then
    ok "Active players found:"
    while IFS= read -r p; do
        printf "       • %s\n" "$p"
    done <<< "$PLAYERS"
else
    warn "No active media players detected. Why not listen to some music!"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────────────────
if [ "$MISSING" -eq 0 ]; then
    echo -e "${GRN}All checks passed. Run music2/music.sh to start all music scripts or music2/start-lyrics-conky.sh to start lyrics only.${NC}"
else
    echo -e "${RED}Some checks failed. Fix the above before starting.${NC}"
    echo ""
    echo "Quick install of all required packages:"
    echo "  sudo apt install conky playerctl gawk jq wget"
fi

echo ""
