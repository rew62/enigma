#!/usr/bin/env bash
# build-conky.sh - reference build commands for enigma's two conky versions:
#
#   build_production_1223  v1.22.3 -> /usr/local/bin/conky          (sudo)
#   build_1223_sidecar     v1.22.3 -> ~/.local/conky-1223,          (no sudo)
#                            symlinked as ~/.local/bin/conky-1223
#   build_1198_sidecar     v1.19.8 -> /usr/local/conky-198,         (sudo)
#                            symlinked as /usr/local/bin/conky-198
#
# Pick per machine: where production is already a self-built 1.19.8 at
# ~/.local (prod-parity flags: defaults + WLAN/PULSEAUDIO/CURL/RSS/
# LUA_RSVG/AUDACIOUS/ICONV/IRC/ICAL), leave it alone and add
# build_1223_sidecar. On a fresh machine, build_production_1223.
#
# Why BUILD_XINPUT=ON is non-negotiable on 1.22.x: conky flipped the
# BUILD_XINPUT default from true (1.19.8) to false (1.22.x, "(slow)") in
# cmake/ConkyBuildOptions.cmake. On Cinnamon/Muffin, the non-XInput
# fallback never delivers ButtonPress/ButtonRelease to an own_window with
# undecorated+below hints (Motion/Enter events still arrive fine) -- so
# every window.lua ctrl-click/shift-click mouse hook in this suite
# silently stops working unless BUILD_XINPUT=ON. See upstream git log
# "Disable Xinput by default (#1920)".
#
# Each build uses its own install prefix: conky bakes an absolute
# PACKAGE_LIBDIR into the binary at compile time for its Lua cairo/imlib2
# bindings, so two versions sharing a prefix would load each other's .so
# files (ABI mismatch) and clobber each other on every rebuild.
#
# This script is reference/copy-paste material, not meant to be run
# unattended top-to-bottom. Uncomment the function call you need at the
# bottom, or copy the function body directly.
#
# v1 2026-07-06 @rew62
set -euo pipefail

# ─── build dependencies (Debian/Ubuntu/Mint) ────────────────────────────────
# Required for the flag sets below:
# apt install -y build-essential cmake \
#     libcairo2-dev libimlib2-dev liblua5.4-dev \
#     libx11-dev libxext-dev libxdamage-dev libxfixes-dev libxft-dev \
#     libxi-dev libxinerama-dev libxcb1-dev libxcb-render0-dev libxcb-shm0-dev \
#     libfontconfig-dev libice-dev libsm-dev libncurses-dev libiw-dev
#
# Only if reproducing the ~/.local prod-parity 1.19.8 extras (none of which
# the suite actually uses -- see note above build_1223_sidecar):
# apt install -y libcurl4-openssl-dev libxml2-dev libical-dev \
#     libpulse-dev librsvg2-dev

BUILD_ROOT="$HOME/bin"   # shallow clones land in $BUILD_ROOT/conky-<ver>-build

# Shared 1.22.3 flag set, validated on the test machine (captured from
# build/CMakeCache.txt after fixing the mouse-hook regression). The only
# flag that matters for that regression is BUILD_XINPUT=ON; the rest is
# feature selection covering everything the suite uses.
CMAKE_FLAGS_1223=(
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
    # Without RELEASE=ON the binary reports "1.22.3-pre-<hash>" even when
    # built from the exact release tag (cosmetic, but confuses version checks)
    -DRELEASE=ON
    -DBUILD_XINPUT=ON
    -DBUILD_X11=ON
    -DBUILD_MOUSE_EVENTS=ON
    -DBUILD_LUA_CAIRO=ON
    -DBUILD_LUA_CAIRO_XLIB=ON
    -DBUILD_LUA_IMLIB2=ON
    -DBUILD_IMLIB2=ON
    -DBUILD_ARGB=ON
    -DBUILD_XFT=ON
    -DBUILD_XDBE=ON
    -DBUILD_XSHAPE=ON
    -DBUILD_XFIXES=ON
    -DBUILD_XDAMAGE=ON
    -DBUILD_XINERAMA=ON
    -DBUILD_NCURSES=ON
    -DBUILD_HDDTEMP=ON
    -DBUILD_APCUPSD=ON
    -DBUILD_IOSTATS=ON
    -DBUILD_IPV6=ON
    -DBUILD_PORT_MONITORS=ON
    -DBUILD_MPD=ON
    -DBUILD_MOC=ON
    -DBUILD_CMUS=ON
    -DBUILD_IBM=ON
    -DBUILD_OLD_CONFIG=ON
    -DBUILD_BUILTIN_CONFIG=ON
    -DBUILD_I18N=ON
    -DBUILD_MATH=ON
    -DBUILD_OPENSOUNDSYS=ON
    -DBUILD_COLOUR_NAME_MAP=ON
    -DBUILD_CURL=OFF -DBUILD_RSS=OFF -DBUILD_ICAL=OFF -DBUILD_MYSQL=OFF
    -DBUILD_PULSEAUDIO=OFF -DBUILD_JOURNAL=OFF -DBUILD_DOCS=OFF
    -DBUILD_TESTING=OFF -DBUILD_WAYLAND=OFF
    -DBUILD_ICONV=OFF -DBUILD_INTEL_BACKLIGHT=OFF -DBUILD_NVIDIA=OFF
    -DBUILD_IRC=OFF -DBUILD_HTTP=OFF -DBUILD_AUDACIOUS=OFF
    -DBUILD_XMMS2=OFF -DBUILD_LUA_RSVG=OFF -DBUILD_LUA_TEXT=OFF
    -DBUILD_EXTRAS=OFF
    # WLAN is off by default upstream regardless of libiw-dev; needed for
    # ${wireless_essid}/${wireless_link_qual_perc} (nsd/nsd2/network
    # widgets) -- without it those are "unknown variable" every frame,
    # even on machines that are wired-only (requires libiw-dev)
    -DBUILD_WLAN=ON
)

# Shallow-clone a tag into $BUILD_ROOT/conky-<name>-build/source-code and
# echo the path. Existing shallow clones of OTHER tags (e.g. the old
# conky-19-build) cannot be re-checked-out to a new tag -- always clone
# the tag you need.
fetch_source() {
    local tag="$1" name="$2"
    local dir="$BUILD_ROOT/conky-$name-build/source-code"
    if [ ! -d "$dir/.git" ]; then
        mkdir -p "$(dirname "$dir")"
        git clone --depth 1 --branch "$tag" \
            https://github.com/brndnmtthws/conky.git "$dir"
    fi
    echo "$dir"
}

# ─── v1.22.3 as production (fresh machine, nothing at ~/.local/bin/conky) ───
build_production_1223() {
    local src; src="$(fetch_source v1.22.3 1223)"
    cd "$src"
    cmake -B build -S . \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        "${CMAKE_FLAGS_1223[@]}"
    cmake --build build -j"$(nproc)"
    # installs /usr/local/bin/conky + /usr/local/lib/conky/*.so
    sudo cmake --install build
}

# ─── v1.22.3 sidecar (machine already runs a 1.19.8 at ~/.local) ────────────
# Deliberately does NOT reproduce the prod 1.19.8's CURL/RSS/ICAL/ICONV/
# IRC/PULSEAUDIO/AUDACIOUS/LUA_RSVG extras: no .rc or .lua in the suite
# uses those conky objects (data fetching happens in Lua/shell; the one
# rsvg reference shells out to rsvg-convert). Diffed against the live
# `conky -v` feature list 2026-07-06.
build_1223_sidecar() {
    local prefix="$HOME/.local/conky-1223"
    local src; src="$(fetch_source v1.22.3 1223)"
    cd "$src"
    cmake -B build -S . \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        "${CMAKE_FLAGS_1223[@]}"
    cmake --build build -j"$(nproc)"
    cmake --install build          # user prefix, no sudo
    ln -sf "$prefix/bin/conky" "$HOME/.local/bin/conky-1223"
    "$HOME/.local/bin/conky-1223" -v | head -3
}

# ─── v1.19.8 sidecar (machine whose production is 1.22.x) ───────────────────
# Trimmed flag set: this build exists for mouse-event behavior comparison,
# not to run the full suite.
build_1198_sidecar() {
    local prefix="/usr/local/conky-198"
    local src; src="$(fetch_source v1.19.8 198)"
    cd "$src"
    cmake -B build -S . \
        -DCMAKE_BUILD_TYPE=Release \
        -DRELEASE=ON \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_X11=ON \
        -DBUILD_XINPUT=ON \
        -DBUILD_LUA_CAIRO=ON \
        -DBUILD_LUA_CAIRO_XLIB=ON \
        -DBUILD_LUA_IMLIB2=ON \
        -DBUILD_IMLIB2=ON \
        -DBUILD_ARGB=ON \
        -DBUILD_XFT=ON \
        -DBUILD_XDBE=ON \
        -DBUILD_XSHAPE=ON \
        -DBUILD_XFIXES=ON \
        -DBUILD_XDAMAGE=ON \
        -DBUILD_XINERAMA=ON \
        -DBUILD_CURL=OFF -DBUILD_RSS=OFF -DBUILD_ICAL=OFF -DBUILD_MYSQL=OFF \
        -DBUILD_PULSEAUDIO=OFF -DBUILD_JOURNAL=OFF -DBUILD_DOCS=OFF \
        -DBUILD_TESTING=OFF -DBUILD_WLAN=OFF -DBUILD_WAYLAND=OFF
    cmake --build build -j"$(nproc)"
    sudo cmake --install build
    sudo ln -sf "$prefix/bin/conky" /usr/local/bin/conky-198
}

# ─── usage ──────────────────────────────────────────────────────────────────
# Uncomment exactly one:
# build_production_1223
# build_1223_sidecar
# build_1198_sidecar

echo "This script documents build steps; edit it to uncomment" >&2
echo "build_production_1223, build_1223_sidecar, or build_1198_sidecar." >&2
