-- horoscope.lua - Cairo-rendered daily horoscope (Ohmanda API)
-- Starts on the sign whose date range covers today; left-click cycles the rest.
-- Data: https://ohmanda.com/api/horoscope/<sign>/ -> {sign, date, horoscope},
-- fetched synchronously once per sign per day (RETRY_SECS gate on failure),
-- cached in CACHE_DIR. Stale cache is shown (with its date) if a refetch fails.
-- v1 2026-07-30 @rew62

local HOME       = os.getenv("HOME")
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (HOME .. "/.conky/enigma")
local CACHE_DIR  = "/dev/shm/conky/horoscope"
local RETRY_SECS = 300
local API_URL    = "https://ohmanda.com/api/horoscope/%s/"

package.path = ENIGMA_DIR .. "/scripts/?.lua;" .. package.path
local json    = require("json")
local surface = require("surface")

os.execute("mkdir -p " .. CACHE_DIR)

-- ── layout ──────────────────────────────────────────────────────────────────
local M       = 6
local W       = 154     -- actual window width (minimum_width 154, border_inner_margin 0)
local XR      = W - M   -- right content edge
local TEXT_W  = W - 2 * M
local Y_HDR   = 18      -- header baseline
local Y_SEP   = 25      -- separator rule
local Y_TXT   = 40      -- first body-line baseline
local LINE_H  = 13
local BODY_SZ = 10

-- ── colors ──────────────────────────────────────────────────────────────────
local function mk(h)
    return { math.floor(h / 0x10000) / 255,
             math.floor(h / 0x100) % 256 / 255,
             h % 256 / 255 }
end
local COL = {
    sign = mk(0xD0B8E8),          -- glyph + sign name (espcal zodiac purple)
    date = mk(0xA0A0A0),          -- header date
    div  = mk(0xA0A0A0),          -- separator rule
    text = mk(0xe8e8e8),          -- body text
}

local SIGNS = {
    { sym = "♈", name = "Aries",       sm = 3, sd = 21, em = 4, ed = 19 },
    { sym = "♉", name = "Taurus",      sm = 4, sd = 20, em = 5, ed = 20 },
    { sym = "♊", name = "Gemini",      sm = 5, sd = 21, em = 6, ed = 20 },
    { sym = "♋", name = "Cancer",      sm = 6, sd = 21, em = 7, ed = 22 },
    { sym = "♌", name = "Leo",         sm = 7, sd = 23, em = 8, ed = 22 },
    { sym = "♍", name = "Virgo",       sm = 8, sd = 23, em = 9, ed = 22 },
    { sym = "♎", name = "Libra",       sm = 9, sd = 23, em = 10, ed = 22 },
    { sym = "♏", name = "Scorpio",     sm = 10, sd = 23, em = 11, ed = 21 },
    { sym = "♐", name = "Sagittarius", sm = 11, sd = 22, em = 12, ed = 21 },
    { sym = "♑", name = "Capricorn",   sm = 12, sd = 22, em = 1, ed = 19 },
    { sym = "♒", name = "Aquarius",    sm = 1, sd = 20, em = 2, ed = 18 },
    { sym = "♓", name = "Pisces",      sm = 2, sd = 19, em = 3, ed = 20 },
}

-- ── sign selection: start on the sign whose date range covers today ──────────
local function today_sign_idx()
    local d = tonumber(os.date("%d"))
    local m = tonumber(os.date("%m"))
    for i, z in ipairs(SIGNS) do
        if (m == z.sm and d >= z.sd) or (m == z.em and d <= z.ed) then return i end
    end
    return 1
end

local sign_idx = today_sign_idx()

function horoscope_cycle()
    sign_idx = sign_idx % #SIGNS + 1
    print("enigma-horoscope: sign -> " .. SIGNS[sign_idx].name)
    return true
end

-- ── data ────────────────────────────────────────────────────────────────────
local last_attempt = {}   -- sign -> os.time() of last curl, gates retries

local function decode(raw)
    local ok, d = pcall(json.decode, raw or "")
    if ok and type(d) == "table"
       and type(d.horoscope) == "string" and d.horoscope ~= "" then
        return d
    end
end

local function read_cache(sign)
    local f = io.open(CACHE_DIR .. "/" .. sign .. ".json", "r")
    if not f then return nil end
    local raw = f:read("*a"); f:close()
    return decode(raw)
end

local function fetch(sign)
    local p = io.popen(string.format(
        'curl -sL --max-time 5 "' .. API_URL .. '" 2>/dev/null', sign))
    if not p then return nil end
    local raw = p:read("*a"); p:close()
    local d = decode(raw)
    if d then
        local f = io.open(CACHE_DIR .. "/" .. sign .. ".json", "w")
        if f then f:write(raw); f:close() end
    end
    return d
end

local function get_data(sign)
    local d = read_cache(sign)
    if d and d.date == os.date("%Y-%m-%d") then return d end
    local now = os.time()
    if now - (last_attempt[sign] or 0) >= RETRY_SECS then
        last_attempt[sign] = now
        d = fetch(sign) or d      -- keep the stale copy if the refetch fails
    end
    return d
end

-- ── word wrap (measured off-window so the size hook can share it) ────────────
local wrap_cache = { key = nil, lines = nil }

local function adv(cr, s)
    local e = cairo_text_extents_t:create()
    tolua.takeownership(e)
    cairo_text_extents(cr, s, e)
    return e.x_advance
end

local function wrapped_lines(sign, text)
    local key = sign .. "\1" .. text
    if wrap_cache.key == key then return wrap_cache.lines end

    local cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1)
    local cr = cairo_create(cs)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, BODY_SZ)

    local lines, cur = {}, ""
    for word in text:gmatch("%S+") do
        local test = cur == "" and word or (cur .. " " .. word)
        if cur == "" or adv(cr, test) <= TEXT_W then
            cur = test
        else
            lines[#lines + 1] = cur
            cur = word
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
    wrap_cache.key, wrap_cache.lines = key, lines
    return lines
end

local function fmt_date(iso)
    local y, m, d = iso:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return iso end
    local t = os.time{ year = y, month = m, day = d, hour = 12 }
    return os.date("%b", t) .. " " .. tonumber(d)
end

-- ── window sizing ────────────────────────────────────────────────────────────
-- Called via ${lua_parse conky_horoscope_size} in conky.text to grow the
-- window with the wrapped text (same pattern as ticker.lua's stocks_size).
function conky_horoscope_size()
    local sign = SIGNS[sign_idx].name:lower()
    local d = get_data(sign)
    local n = d and #wrapped_lines(sign, d.horoscope) or 1
    return "${voffset " .. (Y_TXT + n * LINE_H - 12) .. "}"
end

-- ── main draw ────────────────────────────────────────────────────────────────
function conky_draw_horoscope()
    if conky_window == nil then return end

    local z    = SIGNS[sign_idx]
    local sign = z.name:lower()
    local d    = get_data(sign)

    local cs, owns = surface.get()
    if cs == nil then return end
    local cr = cairo_create(cs)

    -- ── header: glyph + sign name | date ─────────────────────────────────
    cairo_select_font_face(cr, "DejaVu Sans Mono", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 15)
    cairo_set_source_rgba(cr, COL.sign[1], COL.sign[2], COL.sign[3], 0.90)
    cairo_move_to(cr, M, Y_HDR)
    cairo_show_text(cr, z.sym)

    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, 11)
    cairo_move_to(cr, M + 17, Y_HDR)
    cairo_show_text(cr, z.name)

    if d and d.date then
        cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 8)
        cairo_set_source_rgba(cr, COL.date[1], COL.date[2], COL.date[3], 1.0)
        local ds = fmt_date(d.date)
        cairo_move_to(cr, XR - adv(cr, ds), Y_HDR)
        cairo_show_text(cr, ds)
    end

    -- ── separator ────────────────────────────────────────────────────────
    cairo_set_line_width(cr, 0.5)
    cairo_set_source_rgba(cr, COL.div[1], COL.div[2], COL.div[3], 0.6)
    cairo_move_to(cr, M, Y_SEP); cairo_line_to(cr, XR, Y_SEP); cairo_stroke(cr)

    -- ── body ─────────────────────────────────────────────────────────────
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, BODY_SZ)
    cairo_set_source_rgba(cr, COL.text[1], COL.text[2], COL.text[3], 1.0)
    local y = Y_TXT
    if d then
        for _, line in ipairs(wrapped_lines(sign, d.horoscope)) do
            cairo_move_to(cr, M, y)
            cairo_show_text(cr, line)
            y = y + LINE_H
        end
    else
        cairo_move_to(cr, M, y)
        cairo_show_text(cr, "fetching horoscope…")
    end

    cairo_destroy(cr)
    surface.put(cs, owns)
end
