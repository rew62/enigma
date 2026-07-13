-- ticker.lua - Cairo-rendered compact stock ticker
-- v1 2026-07-04 @rew62

local HOME      = os.getenv("HOME")
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (HOME .. "/.conky/enigma")
local CACHE_DIR = "/dev/shm/conky/stocks"
local CACHE_TTL = 120
local CONF_DIR  = ENIGMA_DIR .. "/widgets"

package.path = ENIGMA_DIR .. "/scripts/?.lua;" .. package.path
local env     = require("env")
local surface = require("surface")

-- ── layout ──────────────────────────────────────────────────────────────────
local M   = 4
local W   = 154     -- actual window width (minimum_width 154, border_inner_margin 0)
local XR  = W - M   -- right content edge (150)
local XP  = 92      -- price column right edge

-- ── colors ──────────────────────────────────────────────────────────────────
local function mk(h)
    return { math.floor(h / 0x10000) / 255,
             math.floor(h / 0x100) % 256 / 255,
             h % 256 / 255 }
end
local COL = {
    head  = mk(0x2D9EEA),          -- symbol / title blue
    price = { 0.62, 0.82, 1.00 }, -- net.lua C_DN down-tick color
    pos   = mk(0x50fa7b),          -- positive change green
    neg   = mk(0xff5555),          -- negative change red
    div   = mk(0xA0A0A0),          -- divider / separator
    white = mk(0xe8e8e8),          -- neutral text
}

-- ── Cairo helpers ────────────────────────────────────────────────────────────
local function set_col(cr, c, a)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], a or 1.0)
end

local function adv(cr, s)
    local e = cairo_text_extents_t:create()
    tolua.takeownership(e)
    cairo_text_extents(cr, s, e)
    return e.x_advance
end

local function dl(cr, x, y, s)
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, s)
end

local function dr(cr, x, y, s)
    cairo_move_to(cr, x - adv(cr, s), y)
    cairo_show_text(cr, s)
end

local function hline(cr, y)
    cairo_move_to(cr, M, y); cairo_line_to(cr, XR, y); cairo_stroke(cr)
end

-- ── data helpers ─────────────────────────────────────────────────────────────
local function load_api_key()
    return env.get("FINNHUB_API_KEY")
end

local function cache_age(symbol)
    local f = io.popen("stat -c %Y " .. CACHE_DIR .. "/" .. symbol .. ".json 2>/dev/null")
    if not f then return math.huge end
    local mtime = tonumber(f:read("*l") or "")
    f:close()
    return mtime and (os.time() - mtime) or math.huge
end

local function read_cache(symbol)
    local f = io.open(CACHE_DIR .. "/" .. symbol .. ".json", "r")
    if not f then return nil end
    local data = f:read("*a"); f:close()
    return data
end

local function fetch_symbol(symbol, key)
    local url   = string.format(
        "https://finnhub.io/api/v1/quote?symbol=%s&token=%s", symbol, key)
    local cache = CACHE_DIR .. "/" .. symbol .. ".json"
    os.execute(string.format(
        [[bash -c 'D=$(curl -s --max-time 10 "%s"); ]]
        .. [[echo "$D" | jq -e ".c != null and .c != 0" >/dev/null 2>&1 ]]
        .. [[&& echo "$D" > "%s"' &]], url, cache))
end

local function refresh_stale(symbols, key)
    for _, sym in ipairs(symbols) do
        if cache_age(sym) >= CACHE_TTL then fetch_symbol(sym, key) end
    end
end

local function read_symbols()
    local symbols = {}
    local f = io.open(CONF_DIR .. "/stock-symbols.conf", "r")
    if not f then return symbols end
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            table.insert(symbols, line)
        end
    end
    f:close()
    return symbols
end

local function fmt_num(n, decimals, show_sign)
    local abs_n  = math.abs(n)
    local s      = string.format("%." .. decimals .. "f", abs_n)
    local int, dec = s:match("^(%d+)(%.%d*)$")
    int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    local sign = show_sign and (n >= 0 and "+" or "-") or (n < 0 and "-" or "")
    return sign .. int .. (dec or "")
end

local function parse_val(json, key)
    if not json then return nil end
    local val = json:match('"' .. key .. '":([%-]?[%d%.]+)')
    return val and tonumber(val)
end

-- ── window sizing ────────────────────────────────────────────────────────────
-- Called via ${lua_parse conky_stocks_size} in conky.text to set window height
-- dynamically based on symbol count.  Formula derived from the Cairo layout:
-- first row y=33, row spacing=14, plus a small bottom margin.
function conky_stocks_size()
    local n = #read_symbols()
    return "${voffset " .. (n * 14 + 9) .. "}"
end

-- ── main draw ────────────────────────────────────────────────────────────────
function conky_draw_stocks()
    if conky_window == nil then return end

    os.execute("mkdir -p " .. CACHE_DIR)

    local key     = load_api_key()
    local symbols = read_symbols()

    local cs, owns = surface.get()
    if cs == nil then return end
    local cr = cairo_create(cs)

    -- ── header row: "Stocks" | "Price" | "Change" ────────────────────────
    cairo_set_line_width(cr, 0.5)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, 11)
    set_col(cr, COL.head)
    dl(cr, M, 15, "Stocks")
    cairo_set_font_size(cr, 9)
    set_col(cr, COL.white)
    dr(cr, XP, 15, "Price")
    dr(cr, XR, 15, "Change")

    -- ── separator ─────────────────────────────────────────────────────────
    set_col(cr, COL.div, 0.6)
    hline(cr, 20)

    -- ── error states ──────────────────────────────────────────────────────
    if #symbols == 0 or not key then
        cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 9)
        set_col(cr, COL.neg)
        dl(cr, M, 33, #symbols == 0 and "no symbols.conf" or "no API key")
        cairo_destroy(cr); surface.put(cs, owns); return
    end

    refresh_stale(symbols, key)

    -- ── data rows ─────────────────────────────────────────────────────────
    cairo_set_font_size(cr, 10)
    local y = 33
    for _, sym in ipairs(symbols) do
        local json    = read_cache(sym)
        local price   = parse_val(json, "c")
        local chg     = parse_val(json, "d")

        local price_s = price and fmt_num(price, 2, false) or "--"
        local chg_s   = chg   and fmt_num(chg,   2, true)  or "--"
        local chg_col = (chg and chg < 0) and COL.neg or COL.pos

        cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        set_col(cr, COL.head)
        dl(cr, M, y, sym)

        cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        set_col(cr, COL.price)
        dr(cr, XP, y, price_s)

        set_col(cr, chg_col)
        dr(cr, XR, y, chg_s)

        y = y + 14
    end

    cairo_destroy(cr)
    surface.put(cs, owns)
end
