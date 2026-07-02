-- scripts/nowplaying.lua
-- Now Playing section: album art, progress bar / live indicator, title/artist/album text
-- Called from loadall.lua with a shared Cairo context
-- v1 2026-07-04 @rew62

local image_path = '/dev/shm/'

-- ── helpers ────────────────────────────────────────────────

local function rgb_to_rgba(color, alpha)
    return ((color / 0x10000) % 0x100) / 255,
           ((color / 0x100)   % 0x100) / 255,
           (color              % 0x100) / 255,
           alpha
end

local function exec_cmd(cmd)
    local h = io.popen(cmd)
    local r = h:read("*a")
    h:close()
    return r
end

local function get_position()
    return tonumber(exec_cmd("playerctl position 2>/dev/null")) or 0
end

local function get_duration()
    return (tonumber(exec_cmd("playerctl metadata mpris:length 2>/dev/null")) or 0) / 1000000
end

local function fmt_time(s)
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local ss = math.floor(s % 60)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, ss) end
    return string.format("%02d:%02d", m, ss)
end

-- live-stream station names often embed "stream" (e.g. "Livestream") --
-- strip it case-insensitively to reclaim width in the narrow text column
local function strip_stream_word(s)
    return (s:gsub("[Ss][Tt][Rr][Ee][Aa][Mm]", "")
             :gsub("%s%s+", " ")
             :gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ── online cover fetch (fallback) ─────────────────────────

local COVER_UA  = "Mozilla/5.0 (X11; Linux x86_64)"
local COVER_TMP = "/dev/shm/nowplaying_cover_raw"
local MAGICK_CMD
do
    local h = io.popen("which magick 2>/dev/null"); local r = h:read("*a"):gsub("%s+$",""); h:close()
    if r ~= "" then MAGICK_CMD = "magick"
    else
        h = io.popen("which convert 2>/dev/null"); r = h:read("*a"):gsub("%s+$",""); h:close()
        if r ~= "" then MAGICK_CMD = "convert" end
    end
end

local function url_encode(s)
    return (s:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- JSON decoder: cjson if available, else the bundled pure-Lua fallback
-- (mirrors owm_fetch.lua/nws_fetch.lua's pattern)
local json_decode
do
    local ok, lib = pcall(require, "cjson")
    if ok then json_decode = lib.decode
    else
        local ok2, lib2 = pcall(require, "json")
        if ok2 then json_decode = lib2.decode end
    end
end

local function decode_json(str)
    if not json_decode then return nil end
    local ok, data = pcall(json_decode, str)
    if not ok then return nil end
    return data
end

-- mirrors Mimod: empty artist → title only; title already contains artist → title only
local function build_search_query(artist, title)
    if artist == "" or title:lower():find(artist:lower(), 1, true) then
        return url_encode(title)
    end
    return url_encode(artist .. " " .. title)
end

local function try_download_cover(url, out)
    if not MAGICK_CMD then return false end
    os.execute(string.format(
        "curl -s -L --fail --max-time 10 -A %q -o %q %q"
        .. " && %s %q -resize 130x130^ -gravity center -extent 130x130 %q >/dev/null 2>&1",
        COVER_UA, COVER_TMP, url, MAGICK_CMD, COVER_TMP, out))
    local f = io.open(out, "r")
    if f then f:close(); return true end
    return false
end

local function fetch_itunes_cover(artist, title, out)
    local q    = build_search_query(artist, title):gsub("%%20", "+")
    local raw  = exec_cmd(string.format(
        "curl -s --max-time 5 -A %q 'https://itunes.apple.com/search?term=%s&media=music&limit=1'",
        COVER_UA, q))
    local data = decode_json(raw)
    local r    = data and data.results and data.results[1]
    local url  = r and r.artworkUrl100 and r.artworkUrl100:gsub("100x100bb", "512x512bb")
    if url and url ~= "" then return try_download_cover(url, out) end
    return false
end

local function fetch_deezer_cover(artist, title, out)
    local q    = build_search_query(artist, title)
    local raw  = exec_cmd(string.format(
        "curl -s --max-time 5 -A %q 'https://api.deezer.com/search?q=%s&limit=1'",
        COVER_UA, q))
    local data = decode_json(raw)
    local d    = data and data.data and data.data[1]
    local url  = d and d.album and d.album.cover_big
    if url and url ~= "" then return try_download_cover(url, out) end
    return false
end

local function fetch_musicbrainz_cover(artist, title, out)
    if artist == "" then return false end
    local ua   = url_encode(artist)
    local ut   = url_encode(title)
    local raw  = exec_cmd(string.format(
        "curl -s --max-time 5 -A %q"
        .. " 'https://musicbrainz.org/ws/2/recording/?query=artist:%s%%20AND%%20recording:%s&fmt=json&limit=1'",
        COVER_UA, ua, ut))
    local data     = decode_json(raw)
    local rec      = data and data.recordings and data.recordings[1]
    local releases = rec and rec.releases
    local mbid     = releases and releases[1] and releases[1].id
    if mbid then
        return try_download_cover("https://coverartarchive.org/release/" .. mbid .. "/front-500", out)
    end
    return false
end

local function fetch_tv_logo(query, out)
    local qfile  = "/dev/shm/nowplaying_tvq"
    local shfile = "/dev/shm/nowplaying_tv.sh"
    local qf = io.open(qfile, "w"); if not qf then return false end
    qf:write(query); qf:close()
    local sf = io.open(shfile, "w"); if not sf then return false end
    sf:write(([=[
#!/bin/bash
query=$(cat '%s')
out='%s'; tmp='%s'; ua='%s'; magick_cmd='%s'
slug_raw=$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed -E 's/ im livestream anschauen//gi; s/ [|] .*//g')
slug_none=$(echo "$slug_raw" | sed 's/[^a-z0-9]//g')
slug_dash=$(echo "$slug_raw" | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
slug_under=$(echo "$slug_raw" | sed -E 's/[^a-z0-9]+/_/g; s/^_|_$//g')
slug_vavoo=$(echo "$query" | sed 's/ /%%20/g')
slug_joyn=$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
tv_country="germany"
if [ -f "$HOME/.cache/weather.json" ]; then
    cc=$(jq -r '.sys.country // empty' "$HOME/.cache/weather.json" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    case "$cc" in
        AT) tv_country="austria" ;; CH) tv_country="switzerland" ;; FR) tv_country="france" ;;
        IT) tv_country="italy"   ;; ES) tv_country="spain"       ;; NL) tv_country="netherlands" ;;
        PL) tv_country="poland"  ;; GB|UK) tv_country="uk"       ;;
    esac
fi
repos=(
    "https://raw.githubusercontent.com/cytec/tvlogos/master"
    "https://raw.githubusercontent.com/Jasmeet181/mediaportal-de-logos/master/Logos"
    "https://raw.githubusercontent.com/tv-logo/tv-logos/main/countries/$tv_country"
    "https://raw.githubusercontent.com/picons/picons/master/build-source/logos"
    "https://raw.githubusercontent.com/iptv-org/logos/master/logos"
    "https://raw.githubusercontent.com/jnk22/kodinerds-iptv/master/logos/tv"
    "https://raw.githubusercontent.com/waipu/waipu-logos/master/logos"
)
candidates=()
for s in "$slug_dash" "$slug_none" "$slug_under"; do
    [ -z "$s" ] && continue
    su=$(echo "$s" | tr '[:lower:]' '[:upper:]')
    sc=$(echo "$s" | sed 's/\(.\)/\u\1/')
    for v in "$s" "$su" "$sc"; do
        for suf in "" "-de" "-hd" "_de" "_hd"; do candidates+=("${v}${suf}"); done
    done
done
if [[ "$slug_dash" == *"-"* ]]; then
    first="${slug_dash%%-*}"
    fu=$(echo "$first" | tr '[:lower:]' '[:upper:]')
    fc=$(echo "$first" | sed 's/\(.\)/\u\1/')
    for v in "$first" "$fu" "$fc"; do
        for suf in "" "-de" "-hd" "_de" "_hd"; do candidates+=("${v}${suf}"); done
    done
fi
unique_candidates=$(printf '%%s\n' "${candidates[@]}" | sort -u)
all_urls=()
all_urls+=("https://www.joyn.de/logos/v1/channel/$slug_joyn.png")
all_urls+=("https://raw.githubusercontent.com/michaz80/vavoo-logos/master/icons/$slug_vavoo.png")
all_urls+=("https://raw.githubusercontent.com/cytec/tvlogos/master/logos/$slug_vavoo.png")
for repo in "${repos[@]}"; do
    while IFS= read -r cand; do [ -z "$cand" ] && continue; all_urls+=("$repo/$cand.png"); done <<< "$unique_candidates"
done
found_dir="/dev/shm/tvlogo_$$"; mkdir -p "$found_dir"; found_flag="$found_dir/found.txt"; pids=()
for url in "${all_urls[@]}"; do
    ( [ -s "$found_flag" ] && exit 0
      code=$(curl -s -o /dev/null -I -w '%%{http_code}' -L --max-time 3 -A "$ua" "$url" 2>/dev/null)
      [ "$code" = "200" ] && echo "$url" >> "$found_flag"
    ) &
    pids+=($!)
    [ $(( ${#pids[@]} %% 15 )) -eq 0 ] && { wait -n 2>/dev/null || true; }
done
while true; do
    [ -s "$found_flag" ] && break
    running=0; for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && running=1 && break; done
    [ $running -eq 0 ] && break; sleep 0.15
done
for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
wait "${pids[@]}" 2>/dev/null
success_url=""; [ -s "$found_flag" ] && success_url=$(head -n1 "$found_flag")
rm -rf "$found_dir"
[ -z "$success_url" ] && exit 1
curl -s -L --fail --max-time 10 -A "$ua" -o "$tmp" "$success_url" \
    && "$magick_cmd" "$tmp" -resize 130x130 -background black -gravity center -extent 130x130 "$out" >/dev/null 2>&1
]=]):format(qfile, out, COVER_TMP, COVER_UA, MAGICK_CMD or "convert"))
    sf:close()
    os.execute("bash " .. shfile)
    os.remove(shfile); os.remove(qfile)
    local f = io.open(out, "r"); if f then f:close(); return true end
    return false
end

local function fetch_online_cover(artist, title, out, is_tv, raw_title)
    if is_tv and is_tv > 0 then
        if fetch_tv_logo(raw_title or title, out) then return true end
    end
    return fetch_deezer_cover(artist, title, out)
        or fetch_itunes_cover(artist, title, out)
        or fetch_musicbrainz_cover(artist, title, out)
end

-- ── drawing helpers ────────────────────────────────────────

local function draw_image(cr, path, x, y, w, h)
    local f = io.open(path, "r")
    if not f then return end
    f:close()
    local img = cairo_image_surface_create_from_png(path)
    local iw  = cairo_image_surface_get_width(img)
    local ih  = cairo_image_surface_get_height(img)
    if iw == 0 or ih == 0 then cairo_surface_destroy(img); return end
    cairo_save(cr)
    cairo_translate(cr, x, y)
    cairo_scale(cr, w / iw, h / ih)
    cairo_set_source_surface(cr, img, 0, 0)
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
    cairo_paint(cr)
    cairo_restore(cr)
    cairo_surface_destroy(img)
    collectgarbage()
end

local function write_text(cr, x, y, text, f)
    f = f or {}
    local font   = f.font   or "Droid Sans"
    local size   = f.size   or 10
    local align  = f.align  or 'l'
    local bold   = f.bold   or false
    local ital   = f.italic or false
    local color  = f.color  or 0xffffff
    local alpha  = f.alpha  or 1.0

    local slant  = ital and CAIRO_FONT_SLANT_ITALIC  or CAIRO_FONT_SLANT_NORMAL
    local weight = bold and CAIRO_FONT_WEIGHT_BOLD   or CAIRO_FONT_WEIGHT_NORMAL

    local te = cairo_text_extents_t:create()
    tolua.takeownership(te)
    cairo_select_font_face(cr, font, slant, weight)
    cairo_set_font_size(cr, size)
    cairo_text_extents(cr, text, te)

    local x_a, y_a = 0, 0
    if align == 'c' then
        x_a = -(te.width / 2 + te.x_bearing)
        y_a = -(te.height / 2 + te.y_bearing)
    elseif align == 'r' then
        x_a = -(te.width + te.x_bearing)
    end

    -- shadow
    cairo_set_source_rgba(cr, 0, 0, 0, 0.8)
    cairo_move_to(cr, x + 1 + x_a, y + 1 + y_a)
    cairo_show_text(cr, text)
    cairo_stroke(cr)
    -- main
    cairo_set_source_rgba(cr, rgb_to_rgba(color, alpha))
    cairo_move_to(cr, x + x_a, y + y_a)
    cairo_show_text(cr, text)
    cairo_stroke(cr)
end

-- trims text (with a trailing "…") until it fits max_w at the given font/size,
-- measuring actual pixel width rather than guessing a character count
local function truncate_to_width(cr, text, max_w, font, size, bold)
    cairo_select_font_face(cr, font, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local te = cairo_text_extents_t:create()
    tolua.takeownership(te)
    cairo_text_extents(cr, text, te)
    if te.width <= max_w then return text end

    local s = text
    while #s > 1 do
        s = s:sub(1, -2)
        local trial = s .. "…"
        cairo_text_extents(cr, trial, te)
        if te.width <= max_w then return trial end
    end
    return s .. "…"
end

local function draw_progress_bar(cr, pct, cfg)
    -- background track
    cairo_rectangle(cr, cfg.x, cfg.y, cfg.width, cfg.height)
    cairo_set_source_rgba(cr, rgb_to_rgba(cfg.bg_color, cfg.bg_alpha))
    cairo_fill(cr)
    -- filled portion
    cairo_rectangle(cr, cfg.x, cfg.y, cfg.width * pct, cfg.height)
    cairo_set_source_rgba(cr, rgb_to_rgba(cfg.fg_color, cfg.fg_alpha))
    cairo_fill(cr)
end

local function draw_times(cr, cfg, pos, total, y_off)
    local elapsed = fmt_time(pos)
    local dur     = fmt_time(total)
    write_text(cr, cfg.x,               y_off, elapsed, {font="Droid Sans", size=9, align="l"})
    write_text(cr, cfg.x + cfg.width,   y_off, dur,     {font="Droid Sans", size=9, align="r"})
end

-- ── public entry point ─────────────────────────────────────

-- y_off: top y coordinate of this section within the conky window
function draw_nowplaying(cr, y_off)
    local win_w    = conky_window and conky_window.width or 154
    local margin   = 2
    local usable_w = win_w - 2 * margin    -- 150
    local center_x = margin + usable_w / 2 -- 77

    local status = exec_cmd("playerctl status 2>/dev/null"):gsub("%s+", "")
    if status ~= "Playing" then
        write_text(cr, center_x, y_off + 80, "Not Playing",
            {font="Droid Sans", size=14, align="c", color=0x888888, alpha=0.7})
        return
    end

    -- Fetch metadata
    local artist  = exec_cmd("playerctl metadata xesam:artist 2>/dev/null"):gsub("%s+$", "")
    local album   = exec_cmd("playerctl metadata xesam:album  2>/dev/null"):gsub("%s+$", "")
    local title   = exec_cmd("playerctl metadata xesam:title  2>/dev/null"):gsub("%s+$", "")
    local art_url = exec_cmd("playerctl metadata mpris:artUrl 2>/dev/null"):gsub("%s+$", "")
    local player  = exec_cmd("playerctl metadata --format '{{playerName}}' 2>/dev/null"):gsub("%s+$", "")
    local art     = image_path .. "tmp.png"

    -- detect TV stream: video player + known stream patterns
    local raw_title = title
    local is_tv = 0
    if player:find("vlc") or player:find("mpv") or player:find("chromium") or player:find("firefox") then
        if     title:find("Joyn")  or artist:find("Joyn")  then is_tv = 1
        elseif title:find("Vavoo") or artist:find("Vavoo") then is_tv = 2
        else is_tv = 3 end
    end

    -- stream split: mirrors Mimod playerctl.sh exactly
    if artist == "" or artist == "null" then
        -- no artist field at all: extract from "Artist - Song" in title
        local sep = title:find(" - ", 1, true)
        if sep then
            artist = title:sub(1, sep - 1)
            title  = title:sub(sep + 3)
        end
    elseif art_url == "" then
        -- artist field is a station/app name; real artist is embedded in title
        local sep = title:find(" - ", 1, true)
        if sep then
            local ta = title:sub(1, sep - 1)
            if ta ~= artist then
                artist = ta
                title  = title:sub(sep + 3)
            end
        end
    end

    -- album art: only fetch on song change or when file is missing
    local SONG_CACHE = "/dev/shm/nowplaying_last_song"
    local cur_song   = artist .. "|" .. title
    local last_song  = ""
    local lf = io.open(SONG_CACHE, "r")
    if lf then last_song = lf:read("*a"):gsub("%s+$", ""); lf:close() end
    local art_f = io.open(art, "r")
    local art_exists = art_f ~= nil
    if art_f then art_f:close() end

    if cur_song ~= last_song or not art_exists then
        os.remove(art)
        local success = false

        -- 1. artUrl provided by the player (covers local files & some streams)
        if art_url:match("^file://") then
            local lp = art_url:gsub("^file://", ""):gsub("%%20", " "):gsub("%%40", "@")
            if MAGICK_CMD then
                os.execute(string.format("%s %q -resize 130x130^ -gravity center -extent 130x130 %q >/dev/null 2>&1", MAGICK_CMD, lp, art))
            end
            local f = io.open(art, "r"); if f then f:close(); success = true end
        elseif art_url:match("^http") then
            success = try_download_cover(art_url, art)
        end

        -- 2. embedded art in the track file
        if not success then
            local url_cmd = "playerctl metadata xesam:url 2>/dev/null"
            local cmd = string.format(
                "ffmpeg -y -i \"$(echo $(%s) | sed 's|file://||;s/%%20/ /g;s/%%40/@/g')\" " ..
                "-an -vcodec png -vframes 1 %s >/dev/null 2>&1", url_cmd, art)
            os.execute(cmd)
            local f = io.open(art, "r"); if f then f:close(); success = true end
        end

        -- 3. online fallback: Deezer → iTunes → MusicBrainz / TV logos
        if not success then
            fetch_online_cover(artist, title, art, is_tv, raw_title)
        end

        local cf = io.open(SONG_CACHE, "w"); if cf then cf:write(cur_song); cf:close() end
    end

    -- ── Layout: vertical card, 150px usable width (x=2..152) ──────────────
    local art_size = 130
    local art_x    = margin + (usable_w - art_size) / 2  -- 12
    local art_y    = y_off

    local slot_y   = art_y + art_size + 8   -- progress-bar / live-row band
    local slot_h   = 24
    local bar_x    = art_x
    local bar_w    = art_size

    local text_max_w = usable_w - 6         -- truncation budget per line
    local title_y     = slot_y + slot_h + 12
    local artist_y    = title_y + 16
    local third_y     = artist_y + 13

    -- Album art
    draw_image(cr, art, art_x, art_y, art_size, art_size)

    -- Progress bar (track) or pulsing LIVE indicator (stream) — same band,
    -- so the text block below never shifts between the two states
    local pos     = get_position()
    local total   = get_duration()
    local is_live = total <= 0

    if not is_live then
        local bar_cfg = {
            x = bar_x, y = slot_y + 6, width = bar_w, height = 4,
            bg_color = 0xffffff, bg_alpha = 0.3,
            fg_color = 0xffffff, fg_alpha = 1.0,
        }
        draw_progress_bar(cr, pos / total, bar_cfg)
        draw_times(cr, bar_cfg, pos, total, slot_y + slot_h - 2)
    else
        local dot_x  = bar_x + 20
        local dot_y  = slot_y + slot_h / 2
        local radii  = {4, 7, 10}
        local widths = {1, 1.2, 1.5}
        local phase  = os.time() % 3
        local ring_a = {}
        for i = 0, 2 do
            local d = (phase - i + 3) % 3
            ring_a[i + 1] = d == 0 and 1.0 or (d == 1 and 0.35 or 0.08)
        end
        -- per-wave half-angles: each arc's endpoints step further out
        local halfa = {
            math.asin(2.5 / radii[1]),
            math.asin(3.5 / radii[2]),
            math.asin(4.5 / radii[3]),
        }

        -- left arcs (((
        for i, r in ipairs(radii) do
            cairo_save(cr)
            cairo_arc(cr, dot_x, dot_y, r, math.pi - halfa[i], math.pi + halfa[i])
            cairo_set_source_rgba(cr, 0.553, 0.867, 1.0, ring_a[i])
            cairo_set_line_width(cr, widths[i])
            cairo_stroke(cr)
            cairo_restore(cr)
        end

        -- central dot (always on)
        cairo_save(cr)
        cairo_arc(cr, dot_x, dot_y, 2.5, 0, 2 * math.pi)
        cairo_set_source_rgba(cr, 0.553, 0.867, 1.0, 1.0)
        cairo_fill(cr)
        cairo_restore(cr)

        -- right arcs )))
        for i, r in ipairs(radii) do
            cairo_save(cr)
            cairo_arc(cr, dot_x, dot_y, r, -halfa[i], halfa[i])
            cairo_set_source_rgba(cr, 0.553, 0.867, 1.0, ring_a[i])
            cairo_set_line_width(cr, widths[i])
            cairo_stroke(cr)
            cairo_restore(cr)
        end

        -- LIVE label + elapsed timer share the same row as the indicator
        write_text(cr, dot_x + radii[3] + 8, dot_y + 4, "LIVE",
            {font="Droid Sans", size=10, bold=true, color=0x98FB98, alpha=1.0})
        if pos > 0 then
            write_text(cr, bar_x + bar_w, dot_y + 4, fmt_time(pos),
                {font="Droid Sans", size=9, align="r", alpha=0.9})
        end
    end

    -- Metadata text: Title/Show, Artist, Album-or-Station — same three slots
    -- regardless of context; only the third line's meaning (and content)
    -- changes between track playback and a live stream.
    local third_text = is_live and strip_stream_word(album) or album
    third_text = third_text:gsub("^%.+%s*", "")  -- drop leading "." cruft (e.g. ".radioparadise.com")

    write_text(cr, center_x, title_y,
        truncate_to_width(cr, title, text_max_w, "Play", 12, true),
        {font="Play", size=12, align="c", bold=true})
    write_text(cr, center_x, artist_y,
        truncate_to_width(cr, artist, text_max_w, "Nimbus Sans", 10, false),
        {font="Nimbus Sans", size=10, align="c"})
    write_text(cr, center_x, third_y,
        truncate_to_width(cr, third_text, text_max_w, "Play", 11, false),
        {font="Play", size=11, align="c", color=0x8dddff, alpha=0.75})
end
