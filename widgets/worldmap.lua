-- worldmap.lua - Compact 150px day/night terminator map + sunrise/daylen/sunset footer
-- v1 2026-07-04 @rew62

require 'cairo'
pcall(require, 'cairo_xlib')  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local SCRIPT_DIR = (debug.getinfo(1, 'S').source:match("@?(.*/)" ) or "./")
local CACHE_DIR  = os.getenv("CONKY_CACHE_DIR") or "/dev/shm/conky"
local OWM_JSON   = CACHE_DIR .. "/owm_current.json"
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma"

package.path = ENIGMA_DIR .. "/scripts/?.lua;" .. package.path
local env = require("env")

local MAP_X  = 2
local MAP_Y  = 2
local MAP_W  = 150
local MAP_H  = MAP_W / 2    -- 75px  (2:1 equirectangular)
local DOT_R  = 0.65

local SUN_CENTERED = true

local BG    = {0.04, 0.10, 0.30, 0.75}
local DAY   = {0.88, 0.94, 1.00, 1.00}
local NIGHT = {0.12, 0.26, 0.62, 0.88}

local TWIL_HALF = 0.11   -- ~±6-7° twilight band

local dots_loaded = false
local world_dots  = {}
local loc_lat, loc_lon = nil, nil

local function load_location()
    if loc_lat then return end
    loc_lat = tonumber(env.get("LAT"))
    loc_lon = tonumber(env.get("LON"))
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

local function lerp(a, b, t) return a + (b - a) * t end

local function load_dots()
    if dots_loaded then return end
    dofile(SCRIPT_DIR .. "dots4.lua")
    world_dots  = WORLD_DOTS
    dots_loaded = true
end

local function sun_position()
    local d   = os.date("!*t")
    local utc = d.hour + d.min / 60.0 + d.sec / 3600.0
    local dec = math.rad(23.45 * math.sin(math.rad(360.0 / 365.0 * (d.yday - 81))))
    return dec, -(utc - 12.0) * 15.0
end

local function sin_altitude(dlat, dlon, dec, sun_lon)
    local lat_r = math.rad(dlat)
    local H     = math.rad(dlon - sun_lon)
    return math.sin(lat_r) * math.sin(dec)
         + math.cos(lat_r) * math.cos(dec) * math.cos(H)
end

local function illumination(sa)
    return clamp((sa + TWIL_HALF) / (2.0 * TWIL_HALF), 0.0, 1.0)
end

-- equirectangular: lon/lat → pixel xy, centred on clon
local function to_px(lon, lat, clon)
    local rel = ((lon - clon) % 360)
    if rel > 180 then rel = rel - 360 end
    return MAP_X + (rel + 180.0) / 360.0 * MAP_W,
           MAP_Y + (90.0 - lat)  / 180.0 * MAP_H
end

-- =========================================================================
-- Footer: sunrise / day length / sunset
-- =========================================================================
local FOOTER_Y   = MAP_Y + MAP_H + 14   -- text baseline below map
local GLYPH_FONT = "MonaspiceNe Nerd Font Mono"
local TEXT_FONT  = "Rubik"
local ICON_SZ    = 22
local RISE_DY    = 3     -- px nudge for sunrise glyph (+down, -up)
local SET_DY     = 4     -- px nudge for sunset glyph (+down, -up)
local TIME_SZ    = 10
local DAYL_SZ    = 10

-- Colors from arc6.lua sun labels
local COL_SR_ICON = { 0xFF/255, 0xB7/255, 0x4D/255, 1.0 }  -- FFB74D
local COL_SR_TIME = { 0xFF/255, 0xEC/255, 0xB3/255, 1.0 }  -- FFECB3
local COL_SS_TIME = { 0xFF/255, 0xAB/255, 0x91/255, 1.0 }  -- FFAB91
local COL_SS_ICON = { 0xFF/255, 0x70/255, 0x43/255, 1.0 }  -- FF7043
local COL_DAYL    = { 0.85, 0.85, 0.85, 1.0 }

local function read_owm_ts(key)
    local f = io.open(OWM_JSON, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return tonumber(s:match('"' .. key .. '"%s*:%s*(%d+)'))
end

local function fmt_time_ts(ts)
    if not ts then return "--:--" end
    return os.date("%I:%M", ts):gsub("^0", "") .. os.date("%p", ts):lower():sub(1,1)
end

local function day_length_str(sr_ts, ss_ts)
    if not sr_ts or not ss_ts then return "--h --m" end
    local secs = ss_ts - sr_ts
    return string.format("%dh %dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
end

local function draw_footer(cr)
    local sr_ts  = read_owm_ts("sunrise")
    local ss_ts  = read_owm_ts("sunset")
    local sr_str = fmt_time_ts(sr_ts)
    local ss_str = fmt_time_ts(ss_ts)
    local dl_str = day_length_str(sr_ts, ss_ts)

    -- Nerd Font glyphs: 󰖜 sunrise (U+F059C), 󰖛 sunset (U+F059B)
    local GLYPH_RISE = "󰖜"
    local GLYPH_SET  = "󰖛"

    local ext  = cairo_text_extents_t:create(); tolua.takeownership(ext)
    local y    = FOOTER_Y
    local lx   = MAP_X                  -- left anchor
    local rx   = MAP_X + MAP_W          -- right anchor
    local cx   = MAP_X + MAP_W / 2      -- center

    cairo_save(cr)
    cairo_new_path(cr)

    -- ── Left: [󰖜] [rise time] ────────────────────────────────────────────────
    local x = lx
    cairo_select_font_face(cr, GLYPH_FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, ICON_SZ)
    cairo_set_source_rgba(cr, COL_SR_ICON[1], COL_SR_ICON[2], COL_SR_ICON[3], COL_SR_ICON[4])
    cairo_move_to(cr, x, y + RISE_DY)
    cairo_show_text(cr, GLYPH_RISE)
    cairo_text_extents(cr, GLYPH_RISE, ext)
    x = x + ext.x_advance + 3

    cairo_select_font_face(cr, TEXT_FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, TIME_SZ)
    cairo_set_source_rgba(cr, COL_SR_TIME[1], COL_SR_TIME[2], COL_SR_TIME[3], COL_SR_TIME[4])
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, sr_str)

    -- ── Right: [set time] [󰖛] ───────────────────────────────────────────────
    cairo_select_font_face(cr, TEXT_FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, TIME_SZ)
    cairo_text_extents(cr, ss_str, ext)
    local tw = ext.x_advance

    cairo_select_font_face(cr, GLYPH_FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, ICON_SZ)
    cairo_text_extents(cr, GLYPH_SET, ext)
    local gw = ext.x_advance

    x = rx - tw - 2 - gw

    cairo_select_font_face(cr, TEXT_FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, TIME_SZ)
    cairo_set_source_rgba(cr, COL_SS_TIME[1], COL_SS_TIME[2], COL_SS_TIME[3], COL_SS_TIME[4])
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, ss_str)

    cairo_select_font_face(cr, GLYPH_FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, ICON_SZ)
    cairo_set_source_rgba(cr, COL_SS_ICON[1], COL_SS_ICON[2], COL_SS_ICON[3], COL_SS_ICON[4])
    cairo_move_to(cr, x + tw + 2, y + SET_DY)
    cairo_show_text(cr, GLYPH_SET)

    -- ── Center: day length ───────────────────────────────────────────────────
    cairo_select_font_face(cr, TEXT_FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, DAYL_SZ)
    cairo_text_extents(cr, dl_str, ext)
    cairo_set_source_rgba(cr, COL_DAYL[1], COL_DAYL[2], COL_DAYL[3], COL_DAYL[4])
    cairo_move_to(cr, cx - (ext.width / 2 + ext.x_bearing), y)
    cairo_show_text(cr, dl_str)

    cairo_new_path(cr)
    cairo_restore(cr)
end

-- =========================================================================
-- Main draw hook
-- =========================================================================
function conky_draw_worldmap()
    if conky_window == nil then return end
    load_dots()
    load_location()

    local cs = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable,
        conky_window.visual,  conky_window.width, conky_window.height)
    local cr = cairo_create(cs)

    -- clip everything to the map rectangle
    cairo_rectangle(cr, MAP_X, MAP_Y, MAP_W, MAP_H)
    cairo_clip(cr)

    -- background
    cairo_rectangle(cr, MAP_X, MAP_Y, MAP_W, MAP_H)
    cairo_set_source_rgba(cr, BG[1], BG[2], BG[3], BG[4])
    cairo_fill(cr)

    local dec, sun_lon = sun_position()
    local clon = SUN_CENTERED and sun_lon or 0

    -- land dots
    for _, dot in ipairs(world_dots) do
        local sa = sin_altitude(dot[1], dot[2], dec, sun_lon)
        local f  = illumination(sa)
        local x, y = to_px(dot[2], dot[1], clon)
        cairo_arc(cr, x, y, DOT_R, 0, 6.2831853)
        cairo_set_source_rgba(cr,
            lerp(NIGHT[1], DAY[1], f),
            lerp(NIGHT[2], DAY[2], f),
            lerp(NIGHT[3], DAY[3], f),
            lerp(NIGHT[4], DAY[4], f))
        cairo_fill(cr)
    end

    -- explicit terminator curve
    local sin_dec = math.sin(dec)
    local cos_dec = math.cos(dec)
    if math.abs(sin_dec) > 0.001 then
        local first = true
        for px = 0, MAP_W do
            local rel      = (px / MAP_W) * 360.0 - 180.0
            local H        = math.rad(clon + rel - sun_lon)
            local term_lat = math.deg(math.atan(-math.cos(H) * cos_dec / sin_dec))
            local tx       = MAP_X + px
            local ty       = MAP_Y + (90.0 - term_lat) / 180.0 * MAP_H
            if first then cairo_move_to(cr, tx, ty); first = false
            else          cairo_line_to(cr, tx, ty) end
        end
        cairo_set_source_rgba(cr, 0.80, 0.90, 1.0, 0.60)
        cairo_set_line_width(cr, 0.9)
        cairo_stroke(cr)
    end

    -- location marker
    if loc_lat and loc_lon then
        local lx, ly = to_px(loc_lon, loc_lat, clon)
        cairo_arc(cr, lx, ly, 2.8, 0, 6.2831853)
        cairo_set_source_rgba(cr, 1.0, 0.85, 0.10, 0.22)
        cairo_fill(cr)
        cairo_arc(cr, lx, ly, 1.8, 0, 6.2831853)
        cairo_set_source_rgba(cr, 1.0, 0.88, 0.15, 1.00)
        cairo_set_line_width(cr, 0.9)
        cairo_stroke(cr)
        cairo_arc(cr, lx, ly, 0.9, 0, 6.2831853)
        cairo_set_source_rgba(cr, 1.0, 1.00, 0.50, 1.00)
        cairo_fill(cr)
    end

    -- sun marker
    local slat = math.deg(dec)
    local sx, sy = to_px(sun_lon, slat, clon)
    cairo_arc(cr, sx, sy, 4.5, 0, 6.2831853)
    cairo_set_source_rgba(cr, 1.0, 0.85, 0.20, 0.12)
    cairo_fill(cr)
    cairo_arc(cr, sx, sy, 2.5, 0, 6.2831853)
    cairo_set_source_rgba(cr, 1.0, 0.88, 0.30, 0.38)
    cairo_fill(cr)
    cairo_arc(cr, sx, sy, 1.2, 0, 6.2831853)
    cairo_set_source_rgba(cr, 1.0, 0.95, 0.55, 1.00)
    cairo_fill(cr)

    -- reset clip, draw subtle border
    cairo_reset_clip(cr)
    cairo_rectangle(cr, MAP_X, MAP_Y, MAP_W, MAP_H)
    cairo_set_source_rgba(cr, 0.30, 0.50, 0.90, 0.18)
    cairo_set_line_width(cr, 0.8)
    cairo_stroke(cr)

    draw_footer(cr)
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
