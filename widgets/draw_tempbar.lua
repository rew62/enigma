-- draw_tempbar.lua - 150px current conditions: header + temp bar + emoji+desc
-- Row 0 (y=  0..18): location (left) + last-update time (right)
-- Row 1 (y= 18..48): temperature range bar
-- Row 2 (y= 48..70): emoji icon (left, size 14) + OWM desc (right-aligned)
-- v1 2026-07-04 @rew62

require 'cairo'

package.path = package.path .. ";./?.lua;../?.lua;"
    .. (os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma") .. "/scripts/?.lua"

local SFNT             = "Sans"
local FONT_EMOJI       = "Noto Sans Symbols2"
local TODAY_HIGH_CACHE = (os.getenv("CONKY_CACHE_DIR") or "/dev/shm/conky") .. "/today_high.cache"

-- mtime cache for the OWM JSON → "last update" time in header
local _mtime_cache   = nil
local _mtime_checked = 0

local function owm_update_time()
    local now = os.time()
    if _mtime_cache and (now - _mtime_checked) < 300 then
        return os.date("%I:%M %p", _mtime_cache):gsub("^0", "")
    end
    local h = io.popen("stat -c %Y /dev/shm/conky/owm_current.json 2>/dev/null")
    if not h then return _mtime_cache and os.date("%I:%M %p", _mtime_cache):gsub("^0", "") or "--:--" end
    local t = tonumber(h:read("*l"))
    h:close()
    if t then _mtime_cache = t; _mtime_checked = now end
    return _mtime_cache and os.date("%I:%M %p", _mtime_cache):gsub("^0", "") or "--:--"
end

local function save_today_high(temp)
    local f = io.open(TODAY_HIGH_CACHE, "w")
    if f then f:write(os.date("%Y-%m-%d") .. ":" .. tostring(temp)); f:close() end
end

local function load_today_high()
    local f = io.open(TODAY_HIGH_CACHE, "r")
    if not f then return nil end
    local s = f:read("*l"); f:close()
    local date, temp = (s or ""):match("^(%d%d%d%d%-%d%d%-%d%d):(%d+)$")
    return (date == os.date("%Y-%m-%d")) and tonumber(temp) or nil
end

-- ── Layout ───────────────────────────────────────────────────────────────────
local HDR_Y   = 13   -- header text baseline
local HDR_OFF = 14   -- pixels consumed by header row

-- Temp bar (shifted down by HDR_OFF from the original draw_tempbar layout)
local LX        = 22
local RX        = 132
local Y_BAR     = 13 + HDR_OFF   -- 27
local LINE_COL  = "89b4fa"
local LINE_W    = 0.5
local TICK_H    = 10
local TEMP_SZ   = 11
local LABEL_SZ  = 11
local LABEL_GAP = 4

-- Description row
local Y_DESC    = 35 + HDR_OFF   -- 49
local DESC_SZ   = 9
local EMOJI_SZ  = 14

-- ── Header colours ────────────────────────────────────────────────────────────
local C_LOC  = { 0x2D/255, 0x9E/255, 0xEA/255 }
local C_TIME = { 0.40, 0.60, 0.92 }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function hex_to_rgba(hex, a)
    hex = (hex or "A0A0A0"):gsub("#", "")
    return tonumber(hex:sub(1,2),16)/255,
           tonumber(hex:sub(3,4),16)/255,
           tonumber(hex:sub(5,6),16)/255,
           (a == nil and 1 or a)
end

local function temp_color(f)
    local stops = {
        {  0, 1.00, 1.00, 1.00},
        { 32, 0.75, 0.88, 1.00},
        { 45, 0.30, 0.80, 0.65},
        { 55, 0.30, 0.88, 0.35},
        { 65, 0.60, 0.95, 0.20},
        { 75, 1.00, 0.95, 0.00},
        { 85, 1.00, 0.50, 0.00},
        { 95, 1.00, 0.15, 0.00},
        {110, 0.50, 0.00, 0.00},
    }
    if f <= stops[1][1] then return stops[1][2], stops[1][3], stops[1][4] end
    if f >= stops[#stops][1] then return stops[#stops][2], stops[#stops][3], stops[#stops][4] end
    for i = 1, #stops - 1 do
        if f >= stops[i][1] and f <= stops[i+1][1] then
            local u = (f - stops[i][1]) / (stops[i+1][1] - stops[i][1])
            return stops[i][2] + u*(stops[i+1][2]-stops[i][2]),
                   stops[i][3] + u*(stops[i+1][3]-stops[i][3]),
                   stops[i][4] + u*(stops[i+1][4]-stops[i][4])
        end
    end
    return 1, 1, 1
end

-- ── Draw ──────────────────────────────────────────────────────────────────────

local function do_draw(cr)
    local w = conky_window and conky_window.width or 150
    local te = cairo_text_extents_t:create(); tolua.takeownership(te)

    -- ── Row 0: location (left) + update time (right) ─────────────────────────
    local loc_raw = owm_get("location")
    local loc = (loc_raw ~= "N/A" and loc_raw ~= "") and loc_raw or "Weather"

    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, 9)
    cairo_set_source_rgba(cr, C_LOC[1], C_LOC[2], C_LOC[3], 1.0)
    cairo_move_to(cr, 0, HDR_Y)
    cairo_show_text(cr, loc)

    local upd = owm_update_time()
    cairo_select_font_face(cr, "Roboto", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 9)
    cairo_text_extents(cr, upd, te)
    cairo_set_source_rgba(cr, C_TIME[1], C_TIME[2], C_TIME[3], 0.95)
    cairo_move_to(cr, w - te.x_bearing - te.width, HDR_Y)
    cairo_show_text(cr, upd)

    -- ── Row 1: temperature range bar ─────────────────────────────────────────
    local lx = LX
    local rx = RX
    local y  = Y_BAR

    local cur_f = tonumber(owm_get("temp"))
    local lo_n, hi_n
    local fc = type(get_forecast) == "function" and get_forecast() or nil
    if fc and fc[1] then
        lo_n = fc[1].temp_low
        if fc[1].temp_high then
            hi_n = fc[1].temp_high
            save_today_high(hi_n)
        else
            hi_n = load_today_high()
        end
    end

    local br, bg, bb = hex_to_rgba(LINE_COL)
    cairo_save(cr)
    cairo_new_path(cr)
    cairo_set_source_rgba(cr, br, bg, bb, 1.0)
    cairo_set_line_width(cr, LINE_W)
    cairo_move_to(cr, lx, y); cairo_line_to(cr, rx, y); cairo_stroke(cr)

    cairo_set_line_width(cr, 1.5)
    for _, x in ipairs({lx, rx}) do
        cairo_move_to(cr, x, y - TICK_H / 2)
        cairo_line_to(cr, x, y + TICK_H / 2)
        cairo_stroke(cr)
    end

    if cur_f and lo_n then
        local bar_w = rx - lx
        local t
        if hi_n then
            local range = hi_n - lo_n
            t = range > 0 and math.max(0, math.min(1, (cur_f - lo_n) / range)) or 0.5
        else
            t = 0.5
        end
        local cx_r  = lx + t * bar_w
        local rr, rg, rb = temp_color(cur_f)
        local temp_str = string.format("%.0f°", cur_f)
        local ext = cairo_text_extents_t:create(); tolua.takeownership(ext)
        cairo_select_font_face(cr, SFNT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, TEMP_SZ)
        cairo_text_extents(cr, temp_str, ext)
        local vw = ext.x_bearing + ext.width
        local tx = math.max(lx - ext.x_bearing,
                   math.min(cx_r - ext.x_bearing - ext.width / 2,
                            rx - vw))
        local ty = y - ext.y_bearing - ext.height / 2
        cairo_set_source_rgba(cr, rr, rg, rb, 1.0)
        cairo_move_to(cr, tx, ty); cairo_show_text(cr, temp_str)
    end

    if lo_n then
        local lo_str = string.format("%.0f°", lo_n)
        local hi_str = hi_n and string.format("%.0f°", hi_n) or "--"
        local ext = cairo_text_extents_t:create(); tolua.takeownership(ext)
        cairo_select_font_face(cr, SFNT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, LABEL_SZ)
        cairo_text_extents(cr, lo_str, ext)
        local dy = ext.height / 2
        cairo_set_source_rgba(cr, 0.40, 0.75, 1.00, 1.0)
        cairo_text_extents(cr, lo_str, ext)
        cairo_move_to(cr, lx - LABEL_GAP - ext.x_advance, y + dy); cairo_show_text(cr, lo_str)
        cairo_set_source_rgba(cr, 0.90, 0.35, 0.35, 1.0)
        cairo_move_to(cr, rx + LABEL_GAP, y + dy); cairo_show_text(cr, hi_str)
    end

    -- ── Row 2: emoji icon (left) + conditions description (right-aligned) ────
    local emoji_raw = owm_get("icon_emoji") or ""
    local emoji     = emoji_raw:gsub("\xef\xb8\x8f", "")  -- strip U+FE0F color selector

    if emoji ~= "" then
        cairo_select_font_face(cr, FONT_EMOJI, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, EMOJI_SZ)
        cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0)
        cairo_move_to(cr, 0, Y_DESC)
        cairo_show_text(cr, emoji)
    end

    local desc_raw = owm_get("desc")
    local desc     = (desc_raw ~= "N/A" and desc_raw ~= "") and desc_raw or ""
    if #desc > 0 then
        desc = desc:sub(1,1):upper() .. desc:sub(2)
        cairo_select_font_face(cr, SFNT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, DESC_SZ)
        cairo_text_extents(cr, desc, te)
        cairo_set_source_rgba(cr, 0.80, 0.80, 0.80, 1.0)
        cairo_move_to(cr, w - te.x_bearing - te.width, Y_DESC)
        cairo_show_text(cr, desc)
    end

    cairo_new_path(cr)
    cairo_restore(cr)
end

-- ── Update + entry point ──────────────────────────────────────────────────────

function tempbar_update()
    if type(weather_update)  == "function" then weather_update()  end
    if type(conky_owm_fetch) == "function" then conky_owm_fetch() end
end

function conky_weather_main()
    if conky_window == nil then return end
    local cs = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable,
        conky_window.visual,  conky_window.width, conky_window.height)
    local cr = cairo_create(cs)
    local ok, err = pcall(do_draw, cr)
    if not ok then print("tempbar draw error: " .. tostring(err)) end
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
