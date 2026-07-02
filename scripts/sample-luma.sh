#!/usr/bin/env bash
# sample-luma.sh - sample wallpaper luminance and write to /dev/shm/enigma_luma
#
# Output: single float 0.0 (black) .. 1.0 (white)
# theme.lua reads this at widget startup to derive bg_alpha automatically.
# v1 2026-07-04 @rew62

OUTPUT="/dev/shm/conky/enigma_luma"

# --- find wallpaper path (try sources in priority order) ---
wallpaper=""

# 1. gsettings (GNOME / Cinnamon / Mint)
if [[ -z "$wallpaper" ]]; then
    raw=$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null)
    path="${raw#\'file://}"; path="${path%\'}"
    [[ -f "$path" ]] && wallpaper="$path"
fi

# 2. feh ~/.fehbg (only useful when feh wrote it, i.e. without --no-fehbg)
if [[ -z "$wallpaper" && -f "$HOME/.fehbg" ]]; then
    path=$(grep -oP "'\K[^']+(?=')" "$HOME/.fehbg" | tail -1)
    [[ -f "$path" ]] && wallpaper="$path"
fi

# 3. nitrogen
if [[ -z "$wallpaper" ]]; then
    cfg="$HOME/.config/nitrogen/bg-saved.cfg"
    if [[ -f "$cfg" ]]; then
        path=$(awk -F= '/^file=/{print $2; exit}' "$cfg")
        [[ -f "$path" ]] && wallpaper="$path"
    fi
fi

# --- compute luminance ---
if [[ -n "$wallpaper" ]]; then
    luma=$(convert "$wallpaper" -colorspace Gray -resize 1x1! -format "%[fx:mean]" info: 2>/dev/null)
    src="$wallpaper"
else
    # fallback: sample the root window pixmap directly
    luma=$(import -window root -resize 1x1! -colorspace Gray -format "%[fx:mean]" info: 2>/dev/null)
    src="root window"
fi

if [[ -z "$luma" ]]; then
    echo "sample-luma: could not determine luma, writing 0.0" >&2
    echo "0.0" > "$OUTPUT"
    exit 1
fi

echo "$luma" > "$OUTPUT"
echo "sample-luma: luma=$luma src=$src"
