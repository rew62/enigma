-- indices2.lua - Cairo-rendered compact index ticker
-- Wired in via scripts/loadall.lua (see WIDGETS["indices2.rc"]).
-- Top "Indices" rows are real index values (DJI/IXIC/GSPC/RUT) from Yahoo's
-- keyless chart API, not ETF proxies. The expanded extra-symbols section
-- uses Finnhub, reading ticker.rc's stock-symbols.conf list and its
-- per-symbol cache files in /dev/shm/conky/stocks directly. Whichever
-- widget's redraw fires first does the fetch; the other just reads the
-- fresh cache, so running both ticker.rc and indices2.rc doesn't double
-- the API calls.
-- v1 2026-07-04 @rew62

local HOME      = os.getenv("HOME")
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (HOME .. "/.conky/enigma")
local CACHE_DIR = "/dev/shm/conky/indices2"
local CACHE_FILE = CACHE_DIR .. "/quotes.json"
local CONF_DIR  = ENIGMA_DIR .. "/widgets"

package.path = ENIGMA_DIR .. "/scripts/?.lua;" .. package.path
local env     = require("env")
local surface = require("surface")

-- Yahoo's chart endpoint is keyless and uncapped -- this TTL just keeps it
-- from being hammered on every 1s redraw.
local YAHOO_TTL = 60

-- Shared with ticker.lua: same cache dir/TTL so both widgets' per-symbol
-- staleness checks line up and only one of them actually fetches.
local STOCKS_CACHE_DIR = "/dev/shm/conky/stocks"
local STOCKS_CACHE_TTL = 120

-- Per-minute cap is 8 credits; that's a hard ceiling no TTL can work around
-- if a single combined fetch needs more than that. ATTEMPT_COOLDOWN (below)
-- is what stops a 429 from turning into a retry-every-second storm.
local ATTEMPT_COOLDOWN = 60

-- ── layout ──────────────────────────────────────────────────────────────────
local M   = 4
local W   = 154     -- actual window width (minimum_width 154, border_inner_margin 0)
local XR  = W - M   -- right content edge (150)
local XP  = 105      -- price column right edge

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

-- Top-section symbols (Yahoo, keyless) and their display labels, matching
-- the names already used in check-stock-index.sh.
local YAHOO_SYMBOLS = { "^GSPC", "^IXIC", "^DJI", "^RUT" }
local YAHOO_NAMES = {
    ["^GSPC"] = "S&P 500",
    ["^IXIC"] = "Nasdaq",
    ["^DJI"]  = "Dow",
    ["^RUT"]  = "Russell",
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
local function load_finnhub_key()
    return env.get("FINNHUB_API_KEY")
end

local function cache_mtime(file)
    local f = io.popen("stat -c %Y " .. file .. " 2>/dev/null")
    if not f then return nil end
    local mtime = tonumber(f:read("*l") or "")
    f:close()
    return mtime
end

local function cache_age(file)
    local mtime = cache_mtime(file)
    return mtime and (os.time() - mtime) or math.huge
end

local function fmt_ttl(s)
    if s >= 60 then return string.format("%dm", math.floor(s / 60 + 0.5)) end
    return string.format("%ds", s)
end

local function read_cache(file)
    local f = io.open(file, "r")
    if not f then return nil end
    local data = f:read("*a"); f:close()
    return data
end

-- Per-symbol Finnhub fetch into the same cache dir/shape ticker.lua uses,
-- so both widgets read and write the exact same files.
local function fetch_stock_symbol(symbol, key)
    local url   = string.format(
        "https://finnhub.io/api/v1/quote?symbol=%s&token=%s", symbol, key)
    local cache = STOCKS_CACHE_DIR .. "/" .. symbol .. ".json"
    os.execute(string.format(
        [[bash -c 'D=$(curl -s --max-time 10 "%s"); ]]
        .. [[echo "$D" | jq -e ".c != null and .c != 0" >/dev/null 2>&1 ]]
        .. [[&& echo "$D" > "%s"' &]], url, cache))
end

-- Yahoo's /v8/finance/chart endpoint is keyless and gives the real index
-- value (Twelve Data's free plan doesn't carry DJI/IXIC/RUT at all and
-- gates SPX behind a paid plan). It only takes
-- one symbol per request though, so loop and merge into the same
-- {"SYM": {"close":...,"change":...}, ...} shape parse_val() expects. Only
-- writes the cache if every symbol in the batch succeeded, so a partial
-- outage can't quietly blank out a symbol that was working fine.
local function fetch_yahoo_batch(symbols, file)
    if #symbols == 0 then return end
    local syms_lit = {}
    for _, s in ipairs(symbols) do table.insert(syms_lit, '"' .. s .. '"') end

    os.execute(string.format(
        [[bash -c 'SYMS=(%s); PARTS=(); for SYM in "${SYMS[@]}"; do ]]
        .. [[R=$(curl -s -A "Mozilla/5.0" --max-time 10 "https://query2.finance.yahoo.com/v8/finance/chart/$SYM?interval=1m&range=1d"); ]]
        .. [[C=$(echo "$R" | jq -r ".chart.result[0].meta.regularMarketPrice // empty"); ]]
        .. [[P=$(echo "$R" | jq -r ".chart.result[0].meta.chartPreviousClose // empty"); ]]
        .. [[if [ -n "$C" ] && [ -n "$P" ]; then CH=$(echo "$C - $P" | bc); PARTS+=("\"$SYM\":{\"close\":$C,\"change\":$CH}"); fi; ]]
        .. [[done; if [ ${#PARTS[@]} -eq ${#SYMS[@]} ]; then (IFS=,; echo "{${PARTS[*]}}") > "%s"; fi' &]],
        table.concat(syms_lit, " "), file))
end

-- Last fetch *attempt* time per cache file, kept in memory for the life of
-- this conky process. Without this, a failed/rejected fetch never updates
-- the cache file's mtime, so cache_age() stays stale and refresh_stale()
-- would otherwise retry every redraw tick (every 1s) -- exactly the kind
-- of hammering that gets a 429 in the first place.
local last_attempt = {}

local function refresh_stale(symbols, file, ttl, fetch_fn)
    if #symbols == 0 then return end
    if cache_age(file) < ttl then return end
    local now = os.time()
    if last_attempt[file] and (now - last_attempt[file]) < ATTEMPT_COOLDOWN then return end
    last_attempt[file] = now
    fetch_fn(symbols)
end

-- Per-symbol staleness check against ticker.lua's shared cache files. If
-- ticker.rc's own redraw already refreshed a symbol within STOCKS_CACHE_TTL,
-- this is a no-op for it -- that's what avoids duplicate Finnhub calls when
-- both widgets are running.
local function refresh_stale_stocks(symbols, key)
    for _, sym in ipairs(symbols) do
        local file = STOCKS_CACHE_DIR .. "/" .. sym .. ".json"
        if cache_age(file) >= STOCKS_CACHE_TTL then
            local now = os.time()
            if not last_attempt[file] or (now - last_attempt[file]) >= ATTEMPT_COOLDOWN then
                last_attempt[file] = now
                fetch_stock_symbol(sym, key)
            end
        end
    end
end

local function read_symbol_file(path)
    local symbols = {}
    local f = io.open(path, "r")
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

-- Shared with ticker.rc -- same stock list, same Finnhub cache.
local function read_extra_symbols() return read_symbol_file(CONF_DIR .. "/stock-symbols.conf") end

local function fmt_num(n, decimals, show_sign)
    local abs_n  = math.abs(n)
    local s      = string.format("%." .. decimals .. "f", abs_n)
    local int, dec = s:match("^(%d+)(%.%d*)$")
    int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    local sign = show_sign and (n >= 0 and "+" or "-") or (n < 0 and "-" or "")
    return sign .. int .. (dec or "")
end

-- A multi-symbol response is keyed by symbol ({"DJI": {...}, ...}); fall
-- back to the unscoped top level in case a single-symbol request ever
-- comes back flat instead.
local function parse_val(json, symbol, key)
    if not json then return nil end
    local scoped = json:match('"' .. symbol .. '":%s*({.-})')
    local val = (scoped or json):match('"' .. key .. '":"?([%-]?[%d%.]+)"?')
    return val and tonumber(val)
end

-- Finnhub's per-symbol quote response is flat ({"c":...,"d":...}), one file
-- per symbol -- matches ticker.lua's parse_val.
local function parse_finnhub(json, key)
    if not json then return nil end
    local val = json:match('"' .. key .. '":([%-]?[%d%.]+)')
    return val and tonumber(val)
end

-- ── window sizing ────────────────────────────────────────────────────────────
-- Called via ${lua_parse conky_indices2_size} in conky.text to set window
-- height dynamically based on symbol count. Mirrors ticker.lua's formula.
-- INDICES2_EXPANDED (toggled by left-click, see loadall.lua) adds the
-- extra-symbols rows plus the divider gap before them.
-- +35 covers the footer separator + refresh-rate/last-refreshed row
-- (20 was too tight -- footer was getting clipped; bumped +15 more).
function conky_indices2_size()
    local n = #YAHOO_SYMBOLS
    local extra_h = 0
    if INDICES2_EXPANDED == true then
        local en = #read_extra_symbols()
        if en > 0 then extra_h = en * 14 + 14 end
    end
    return "${voffset " .. (n * 14 + 9 + extra_h + 35) .. "}"
end

local function draw_row(cr, y, label, price, chg)
    local price_s = price and fmt_num(price, 2, false) or "--"
    local chg_s   = chg   and fmt_num(chg,   2, true)  or "--"
    local chg_col = (chg and chg < 0) and COL.neg or COL.pos

    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    set_col(cr, COL.head)
    dl(cr, M, y, label)

    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    set_col(cr, COL.price)
    dr(cr, XP, y, price_s)

    set_col(cr, chg_col)
    dr(cr, XR, y, chg_s)
end

-- ── main draw ────────────────────────────────────────────────────────────────
function conky_draw_indices2()
    if conky_window == nil then return end

    os.execute("mkdir -p " .. CACHE_DIR)

    local symbols = YAHOO_SYMBOLS

    local cs, owns = surface.get()
    if cs == nil then return end
    local cr = cairo_create(cs)

    -- ── header row: "Indices" | "Price" | "Change" ───────────────────────
    cairo_set_line_width(cr, 0.5)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, 11)
    set_col(cr, COL.head)
    dl(cr, M, 15, "Indices")
    cairo_set_font_size(cr, 9)
    set_col(cr, COL.white)
    dr(cr, XP, 15, "Price")
    dr(cr, XR, 15, "Change")

    -- ── separator ─────────────────────────────────────────────────────────
    set_col(cr, COL.div, 0.6)
    hline(cr, 20)

    refresh_stale(symbols, CACHE_FILE, YAHOO_TTL, function(syms)
        fetch_yahoo_batch(syms, CACHE_FILE)
    end)

    -- Left-click (see loadall.lua) toggles INDICES2_EXPANDED. Only
    -- fetch the extra-symbols list while expanded -- that's what stops the
    -- extra Finnhub calls once collapsed back. Needs a Finnhub key; if
    -- there isn't one, the rows below just fall back to "--" like any
    -- other missing-cache case (same as ticker.rc without a key).
    local extra_symbols = {}
    if INDICES2_EXPANDED == true then
        extra_symbols = read_extra_symbols()
        local fk = load_finnhub_key()
        if fk then
            os.execute("mkdir -p " .. STOCKS_CACHE_DIR)
            refresh_stale_stocks(extra_symbols, fk)
        end
    end

    -- ── data rows ─────────────────────────────────────────────────────────
    cairo_set_font_size(cr, 10)
    local json = read_cache(CACHE_FILE)
    local y = 33
    for _, sym in ipairs(symbols) do
        draw_row(cr, y, YAHOO_NAMES[sym] or sym, parse_val(json, sym, "close"), parse_val(json, sym, "change"))
        y = y + 14
    end

    -- ── expanded rows: individual symbols (shared with ticker.rc) ─────────
    if #extra_symbols > 0 then
        y = y + 4
        set_col(cr, COL.div, 0.6)
        hline(cr, y)
        y = y + 10

        for _, sym in ipairs(extra_symbols) do
            local sjson = read_cache(STOCKS_CACHE_DIR .. "/" .. sym .. ".json")
            draw_row(cr, y, sym, parse_finnhub(sjson, "c"), parse_finnhub(sjson, "d"))
            y = y + 14
        end
    end

    -- ── footer: refresh rate (left) + last refreshed (right) ──────────────
    -- Reflects the indices cache specifically (the always-on data), not the
    -- expanded extra-symbols cache, even when expanded.
    y = y + 4
    set_col(cr, COL.div, 0.6)
    hline(cr, y)
    local y_f = y + 12
    cairo_set_font_size(cr, 9)

    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    set_col(cr, COL.head)
    dl(cr, M, y_f, "ref: ")
    local rate_lbl_w = adv(cr, "ref: ")
    cairo_select_font_face(cr, "Roboto", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    set_col(cr, COL.white)
    dl(cr, M + rate_lbl_w, y_f, fmt_ttl(YAHOO_TTL))

    local mtime = cache_mtime(CACHE_FILE)
    local ts    = mtime and os.date("%I:%M %p", mtime):lower() or "--"

    cairo_select_font_face(cr, "Roboto", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    local ts_w = adv(cr, ts)
    set_col(cr, COL.white)
    cairo_move_to(cr, XR - ts_w, y_f)
    cairo_show_text(cr, ts)

    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    local lbl_w = adv(cr, "updated: ")
    set_col(cr, COL.head)
    cairo_move_to(cr, XR - ts_w - lbl_w, y_f)
    cairo_show_text(cr, "updated: ")

    cairo_destroy(cr)
    surface.put(cs, owns)
end
