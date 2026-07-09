#!/bin/bash
# enigma-config.sh - Setup and configure the enigma conky suite including fonts installed in fonts/ directory
# v2 2026-07-09 @rew62

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env-example"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Font check function ───────────────────────────────────────────────────
run_font_check() {
    echo
    echo -e "${BLUE}Checking fonts...${NC}"
    echo "================================"
    {
        grep -roh --exclude-dir=.git --exclude-dir=dev -I '{font [^}]*}' "$SCRIPT_DIR" | \
            grep -o '{font [^:}]*' | \
            sed 's/{font //';
        grep -rh --exclude-dir=.git --exclude-dir=dev -I "font[0-9]\+ *= *'[^']*'" "$SCRIPT_DIR" | \
            grep -v '^\s*--' | \
            grep -o "font[0-9]\+ *= *'[^']*'" | \
            grep -o "'[^']*'" | \
            tr -d "'" | \
            sed 's/:.*//'
    } | \
        grep -E '^[A-Za-z][A-Za-z0-9 ]+$' | \
        sort -u | \
        while read -r font; do
            if fc-list | grep -qiF "$font"; then
                echo -e "${GREEN}✓ $font${NC}"
            else
                echo -e "${YELLOW}✗ MISSING: $font${NC}"
                if [[ "$font" =~ ^IBM\ Plex ]]; then
                    echo -e "${YELLOW}  → Install with: sudo apt install fonts-ibm-plex${NC}"
                fi
            fi
        done
    echo
}

# ── Font install function ─────────────────────────────────────────────────
run_font_install() {
    local FONT_DIR="$HOME/.local/share/fonts"
    local installed=0

    echo
    echo -e "${BLUE}Installing fonts in $FONT_DIR...${NC}"
    echo "================================"
    mkdir -p "$FONT_DIR"

    while IFS= read -r -d '' src; do
        local family
        family=$(fc-query --format='%{family}\n' "$src" 2>/dev/null | head -n1)
        if [ -n "$family" ] && fc-list | grep -qiF "$family"; then
            echo "  skipped (already installed): $(basename "$src") [$family]"
        else
            cp "$src" "$FONT_DIR/$(basename "$src")"
            echo -e "  ${GREEN}installed: $(basename "$src")${NC}"
            installed=1
        fi
    done < <(find "$SCRIPT_DIR/fonts" -maxdepth 2 -type f \( -iname "*.ttf" -o -iname "*.otf" \) -print0)

    if [ "$installed" -eq 1 ]; then
        fc-cache -f "$FONT_DIR"
        echo -e "${GREEN}✓ Font cache updated${NC}"
    else
        echo "  All fonts already installed."
    fi
    echo
}

# ── Lyrics setup function ─────────────────────────────────────────────────
run_lyrics_check() {
    if [ -f "$SCRIPT_DIR/music2/setup.sh" ]; then
        echo
        read -p "Run lyrics dependency check? (yes/no): " RUN_LYRICS
        if [[ "$RUN_LYRICS" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
            echo -e "${BLUE}Running lyrics dependency check...${NC}"
            echo "================================"
            bash "$SCRIPT_DIR/music2/setup.sh"
        fi
    fi
}

# ── Function to get active internet-facing interface ─────────────────────
get_default_interface() {
    local iface=$(ip route | grep '^default' | head -n1 | awk '{print $5}')
    if [ -z "$iface" ]; then
        iface=$(ip link show | grep -E '^[0-9]+: (eth|wl|en)' | grep 'state UP' | head -n1 | awk -F': ' '{print $2}')
    fi
    echo "$iface"
}

# ── Function to get primary disk device (for I/O graphs) ─────────────────
get_default_disk() {
    lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1; exit}'
}

# ── Geolocation helper ────────────────────────────────────────────────────
_geo_json_get() {
    local json="$1" key="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r "${key} // empty" 2>/dev/null
    else
        python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    keys = '${key}'.lstrip('.').split('.')
    v = d
    for k in keys:
        v = v[k]
    print(v if v is not None else '')
except Exception:
    pass
" <<< "$json" 2>/dev/null
    fi
}

# ── Geolocation function ──────────────────────────────────────────────────
run_geolocation() {
    echo -e "${BLUE}Detecting location...${NC}"
    local _lat="" _lon="" _source="" GEOCLUE_CMD=""

    for _path in "/usr/libexec/geoclue-2.0/demos/where-am-i" "/usr/lib/geoclue-2.0/demos/where-am-i" "/usr/bin/where-am-i"; do
        [[ -x "$_path" ]] && GEOCLUE_CMD="$_path" && break
    done

    if [[ -n "$GEOCLUE_CMD" ]]; then
        local _agent="/usr/lib/geoclue-2.0/demos/agent"
        if [[ -x "$_agent" ]] && ! pgrep -f "$_agent" >/dev/null; then
            "$_agent" &>/dev/null &
            disown
        fi
        local _gc_data
        _gc_data=$(timeout 3s "$GEOCLUE_CMD" --timeout=2 2>/dev/null) || _gc_data=""
        if [[ -n "$_gc_data" ]]; then
            _lat=$(echo "$_gc_data" | grep "Latitude:"  | cut -d: -f2 | tr -d '[:space:]' | sed 's/[^0-9.-]//g')
            _lon=$(echo "$_gc_data" | grep "Longitude:" | cut -d: -f2 | tr -d '[:space:]' | sed 's/[^0-9.-]//g' | sed 's/\.$//')
            _source="geoclue"
        fi
    fi

    if [[ -z "$_lat" || "$_lat" == "null" ]] && command -v python3 &>/dev/null; then
        local _py_data
        _py_data=$(python3 - 2>/dev/null <<'PYEOF'
import gi, sys
try:
    gi.require_version('Geoclue', '2.0')
    from gi.repository import Geoclue
    client = Geoclue.Simple.new_sync('get-location', Geoclue.AccuracyLevel.EXACT, None)
    loc = client.get_location()
    print(loc.get_property('latitude'))
    print(loc.get_property('longitude'))
except Exception:
    sys.exit(1)
PYEOF
) || _py_data=""
        if [[ -n "$_py_data" ]]; then
            _lat=$(echo "$_py_data" | sed -n '1p')
            _lon=$(echo "$_py_data" | sed -n '2p')
            _source="geoclue-dbus"
        fi
    fi

    if [[ -z "$_lat" || "$_lat" == "null" ]]; then
        local _providers=(
            "https://ipapi.co/json|.latitude|.longitude"
            "https://freeipapi.com/api/json|.latitude|.longitude"
            "http://ip-api.com/json|.lat|.lon"
            "https://ipinfo.io/json|.loc|"
        )
        local _purl _lpath _lonpath _gdata _loc
        for _pentry in "${_providers[@]}"; do
            IFS='|' read -r _purl _lpath _lonpath <<< "$_pentry"
            _gdata=$(curl -s --max-time 5 -k "$_purl" 2>/dev/null || wget -qO- -T 5 --no-check-certificate "$_purl" 2>/dev/null) || _gdata=""
            [[ -z "$_gdata" ]] && continue
            if [[ "$_lpath" == ".loc" ]]; then
                _loc=$(_geo_json_get "$_gdata" ".loc") || _loc=""
                if [[ "$_loc" =~ ^(-?[0-9]+\.?[0-9]*),(-?[0-9]+\.?[0-9]*)$ ]]; then
                    _lat="${BASH_REMATCH[1]}"
                    _lon="${BASH_REMATCH[2]}"
                fi
            else
                _lat=$(_geo_json_get "$_gdata" "$_lpath") || _lat=""
                _lon=$(_geo_json_get "$_gdata" "$_lonpath") || _lon=""
            fi
            if [[ -n "$_lat" && "$_lat" != "null" && "$_lat" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                _source="$_purl"
                break
            else
                _lat="" _lon=""
            fi
        done
    fi

    if [[ -n "$_lat" && "$_lat" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        LAT="$_lat"
        LON="$_lon"
        echo -e "${GREEN}✓ Location detected: $LAT, $LON (via $_source)${NC}"
    else
        echo -e "${YELLOW}⚠ Could not determine location automatically.${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Configuration Script${NC}"
echo "================================"
echo
echo -e "${YELLOW}NOTE: This script will update configuration files as needed.${NC}"
echo -e "${YELLOW}Required keys: OWM_API_KEY, CITY_ID, UNITS, LAT, LON${NC}"
if [ -f "$ENV_EXAMPLE" ]; then
    echo -e "${YELLOW}See .env-example for the format reference.${NC}"
fi
echo

# ── Dependencies ─────────────────────────────────────────────────────────
read -p "Install/verify dependencies via apt? (yes/no): " INSTALL_DEPS
if [[ "$INSTALL_DEPS" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
    # Library/font packages with no CLI to probe; apt handles these safely.
    APT_PACKAGES=(python3-ephem fonts-ibm-plex)
    # Package → command it provides. If the command already exists (apt,
    # curl, pip, or source install), skip the apt package rather than
    # shadow or duplicate the user's copy.
    declare -A PKG_CMDS=(
        [conky-all]=conky [tmux]=tmux [curl]=curl [xdotool]=xdotool
        [vnstat]=vnstat [jq]=jq [playerctl]=playerctl
        [librsvg2-bin]=rsvg-convert [imagemagick]=convert
        [luarocks]=luarocks [gcalcli]=gcalcli [git]=git
        [pulseaudio-utils]=pactl [fzf]=fzf
    )
    for pkg in conky-all tmux curl xdotool vnstat jq playerctl \
        librsvg2-bin imagemagick luarocks gcalcli git pulseaudio-utils fzf; do
        cmd=${PKG_CMDS[$pkg]}
        if command -v "$cmd" &>/dev/null; then
            echo "  skipping $pkg: '$cmd' already at $(command -v "$cmd")"
        else
            APT_PACKAGES+=("$pkg")
        fi
    done
    sudo apt install -y "${APT_PACKAGES[@]}"
    echo
fi

# ── Conky capability check ────────────────────────────────────────────────
# The widgets need conky built with Lua Cairo bindings, mouse events,
# ARGB visuals, own_window and Xft; XDBE avoids flicker (double_buffer).
# A self-compiled conky may lack these even though the binary exists.
check_conky_features() {
    if ! command -v conky &>/dev/null; then
        echo -e "${YELLOW}⚠ conky not found on PATH. Install it (e.g. 'sudo apt install conky-all') before starting the suite.${NC}"
        return
    fi
    local info missing=() feat
    info=$(conky -v 2>/dev/null)
    for feat in "Cairo" "Mouse events" "ARGB visual" "Own window" "Xft"; do
        grep -qi "$feat" <<< "$info" || missing+=("$feat")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ conky at $(command -v conky) has all required build features${NC}"
    else
        echo -e "${YELLOW}⚠ conky at $(command -v conky) is missing required build features: ${missing[*]}${NC}"
        echo -e "${YELLOW}  The suite will not work with this build. On Ubuntu/Mint, 'sudo apt install conky-all' provides a full build.${NC}"
    fi
    if ! grep -qi "XDBE" <<< "$info"; then
        echo -e "${YELLOW}⚠ conky built without XDBE (double buffering): widgets will run but may flicker.${NC}"
    fi
}
check_conky_features
echo

# ── Load and display existing .env if present ────────────────────────────
OWM_API_KEY=""; CITY_ID=""; UNITS=""; LAT=""; LON=""; INTERFACE_NAME=""
FINNHUB_API_KEY=""; TWELVEDATA_API_KEY=""; DISK_DEV=""

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    if [ -z "$INTERFACE_NAME" ] || ! ip link show "$INTERFACE_NAME" up &>/dev/null 2>&1; then
        INTERFACE_NAME=$(get_default_interface)
    fi
    if [ -z "$DISK_DEV" ] || [ ! -b "/dev/$DISK_DEV" ]; then
        DISK_DEV=$(get_default_disk)
    fi

    echo -e "${YELLOW}Current configuration:${NC}"
    printf "  %-20s %s\n" "OWM API Key:"        "$OWM_API_KEY"
    printf "  %-20s %s\n" "FinnHub Key:"        "$FINNHUB_API_KEY"
    printf "  %-20s %s\n" "City ID:"            "$CITY_ID"
    printf "  %-20s %s\n" "Latitude:"           "$LAT"
    printf "  %-20s %s\n" "Longitude:"          "$LON"
    printf "  %-20s %s\n" "Temp Unit:"          "$UNITS"
    printf "  %-20s %s\n" "Interface:"          "$INTERFACE_NAME"
    printf "  %-20s %s\n" "Disk device:"        "$DISK_DEV"
    echo

    read -p "Any changes needed? (yes/no): " HAS_CHANGES
    if [[ ! "$HAS_CHANGES" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        echo -e "${GREEN}No changes. Nothing to update.${NC}"
        run_font_install
        run_font_check
        run_lyrics_check
        exit 0
    fi
    echo
else
    # First run — no .env yet, set defaults
    INTERFACE_NAME=$(get_default_interface)
    DISK_DEV=$(get_default_disk)
    echo -e "${YELLOW}No existing configuration found. Please enter your settings.${NC}"
    echo
fi

# ── Geolocation prompt ────────────────────────────────────────────────────
read -p "Identify current location? (yes/no): " GET_LOC
if [[ "$GET_LOC" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
    run_geolocation
    echo
fi

# ── Individual prompts ────────────────────────────────────────────────────
read -p "OWM API Key [$OWM_API_KEY]: " INPUT
OWM_API_KEY=${INPUT:-$OWM_API_KEY}

read -p "FinnHub API Key [$FINNHUB_API_KEY]: " INPUT
FINNHUB_API_KEY=${INPUT:-$FINNHUB_API_KEY}

read -p "City ID [$CITY_ID]: " INPUT
CITY_ID=${INPUT:-$CITY_ID}

read -p "metric (Celsius) or imperial (Fahrenheit) [$UNITS]: " INPUT
UNITS=${INPUT:-$UNITS}

read -p "Latitude [$LAT]: " INPUT
LAT=${INPUT:-$LAT}

read -p "Longitude [$LON]: " INPUT
LON=${INPUT:-$LON}

read -p "Network interface [$INTERFACE_NAME]: " INPUT
INTERFACE_NAME=${INPUT:-$INTERFACE_NAME}

read -p "Disk device for I/O graphs [$DISK_DEV]: " INPUT
DISK_DEV=${INPUT:-$DISK_DEV}

echo
echo -e "${GREEN}Updated configuration:${NC}"
printf "  %-30s %s\n" "OWM API Key:"        "$OWM_API_KEY"
printf "  %-30s %s\n" "FinnHub API Key:"    "$FINNHUB_API_KEY"
printf "  %-30s %s\n" "City ID:"            "$CITY_ID"
printf "  %-30s %s\n" "Temp Unit:"          "$UNITS"
printf "  %-30s %s\n" "Latitude:"           "$LAT"
printf "  %-30s %s\n" "Longitude:"          "$LON"
printf "  %-30s %s\n" "Interface:"          "$INTERFACE_NAME"
printf "  %-30s %s\n" "Disk device:"        "$DISK_DEV"
echo

# ── Files to be updated ───────────────────────────────────────────────────
echo "Files to be updated:"
echo "  - $ENV_FILE"
if crontab -l 2>/dev/null | grep -q "fourmilab-earth.sh"; then
    echo "  - crontab (already installed, will skip)"
else
    echo "  - crontab (will install)"
fi
echo

read -p "Proceed with updates? (yes/no): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
    echo "Configuration cancelled. No files were modified."
    run_font_install
    run_font_check
    run_lyrics_check
    exit 0
fi

# ── Write .env ────────────────────────────────────────────────────────────
# Values written unquoted: the Lua widgets (ticker.lua, indices2.lua)
# match KEY=value literally and would keep the quote characters.
cat > "$ENV_FILE" << EOF
OWM_API_KEY=$OWM_API_KEY
FINNHUB_API_KEY=$FINNHUB_API_KEY
CITY_ID=$CITY_ID
UNITS=$UNITS
LAT=$LAT
LON=$LON
INTERFACE_NAME=$INTERFACE_NAME
DISK_DEV=$DISK_DEV
EOF
# Carry over a Twelve Data key if one was already set (used only by the
# parked dev/twelve.rc widget; no longer prompted for).
[ -n "$TWELVEDATA_API_KEY" ] && echo "TWELVEDATA_API_KEY=$TWELVEDATA_API_KEY" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo -e "${GREEN}✓ Saved $ENV_FILE (permissions: 600)${NC}"

# ── Update crontab ────────────────────────────────────────────────────────
if crontab -l 2>/dev/null | grep -q "fourmilab-earth.sh"; then
    echo "  Crontab entries already installed, skipping."
else
    # "|| true": with no existing crontab, crontab -l exits 1 and set -e
    # would kill the subshell before cat runs — piping an EMPTY crontab to
    # "crontab -", which installs nothing while still reporting success
    (crontab -l 2>/dev/null || true; cat <<EOF
@reboot sleep 15 && DISPLAY=:0 $SCRIPT_DIR/utils/fourmilab-earth.sh > /dev/shm/cron_debug.log 2>&1
*/10 * * * * $SCRIPT_DIR/utils/fourmilab-earth.sh > /dev/shm/cron_debug.log 2>&1
EOF
) | crontab -
    echo -e "${GREEN}✓ Crontab updated${NC}"
fi

echo
echo -e "${GREEN}Configuration complete!${NC}"

# ── Font install then check ───────────────────────────────────────────────
run_font_install
run_font_check
