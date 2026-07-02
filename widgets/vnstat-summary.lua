-- vnstat-summary.lua  Cairo-rendered compact vnstat summary for enigma
-- v1 2026-07-04 @rew62

local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma"
package.path = package.path .. ";./?.lua;../?.lua;"
            .. ENIGMA_DIR .. "/scripts/?.lua"

local cjson
do
    local ok, lib = pcall(require, "cjson")
    if ok then cjson = lib
    else
        local ok2, lib2 = pcall(require, "json")
        if ok2 then cjson = lib2
        else print("FATAL: no JSON library found") end
    end
end

local env = require("env")
local NET_IFACE = env.get("INTERFACE_NAME", "wlp2s0")

-- ── layout ──────────────────────────────────────────────────────────────────
local M   = 2       -- left/right margin (border_inner_margin=2 ignored by Cairo, applied manually)
local W   = 154     -- actual window width (minimum_width 150 + border_inner_margin*2)
local XR  = W - M  -- right content edge (152)
local XUP = 85      -- upload column right edge

-- ── colors ──────────────────────────────────────────────────────────────────
local function mk(h)
    return { math.floor(h / 0x10000) / 255,
             math.floor(h / 0x100) % 256 / 255,
             h % 256 / 255 }
end
local COL = {
    white = mk(0xe8e8e8),
    head  = mk(0x2D9EEA),
    rx    = mk(0x60c888),
    tx    = mk(0xf05555),
    div   = mk(0xA0A0A0),
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

-- ── data helpers ─────────────────────────────────────────────────────────────
local function fmt_compact(b)
    b = tonumber(b) or 0
    local K = 1024
    if     b >= K^4 * 10  then return string.format("%.0fT", b / K^4)
    elseif b >= K^4       then return string.format("%.1fT", b / K^4)
    elseif b >= K^3 * 100 then return string.format("%.0fG", b / K^3)
    elseif b >= K^3 * 10  then return string.format("%.1fG", b / K^3)
    elseif b >= K^3       then return string.format("%.2fG", b / K^3)
    elseif b >= K^2       then return string.format("%.0fM", b / K^2)
    elseif b >= K         then return string.format("%.0fK", b / K)
    else                       return string.format("%dB",   math.floor(b))
    end
end

local function get_vnstat(iface)
    local p = io.popen("vnstat -i " .. iface .. " --json 2>/dev/null")
    if not p then return nil end
    local raw = p:read("*a"); p:close()
    if not raw or raw == "" then return nil end
    local ok, data = pcall(cjson.decode, raw)
    return ok and data or nil
end

local function date_num(d)
    return d.year * 10000 + d.month * 100 + d.day
end

local function week_range()
    local today = os.date("*t")
    local start_wday = (var_WEEK_START == "monday") and 2 or 1
    local days_back  = (today.wday - start_wday + 7) % 7
    local wstart     = os.date("*t", os.time(today) - days_back * 86400)
    return today, wstart
end

-- ── main draw ────────────────────────────────────────────────────────────────
function conky_draw_vnstat_summary()
    if conky_window == nil then return end

    local cs = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable,
        conky_window.visual,  conky_window.width, conky_window.height)
    local cr = cairo_create(cs)

    local iface_name = NET_IFACE

    -- ── title ─────────────────────────────────────────────────────────────
    local Y1 = 15
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, 11)
    set_col(cr, COL.head)
    dl(cr, M, Y1, "vnstat")
    set_col(cr, COL.white)
    dr(cr, XR, Y1, iface_name)

    -- ── divider ───────────────────────────────────────────────────────────
    set_col(cr, COL.div, 0.6)
    cairo_set_line_width(cr, 0.5)
    cairo_move_to(cr, M,  21)
    cairo_line_to(cr, XR, 21)
    cairo_stroke(cr)

    -- ── column headers ────────────────────────────────────────────────────
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, 9)
    set_col(cr, COL.tx)
    dr(cr, XUP, 31, "Upload")
    set_col(cr, COL.rx)
    dr(cr, XR,  31, "Download")

    -- ── separator below headers ───────────────────────────────────────────
    set_col(cr, COL.div, 0.6)
    cairo_move_to(cr, M,  37)
    cairo_line_to(cr, XR, 37)
    cairo_stroke(cr)

    -- ── fetch & locate interface ──────────────────────────────────────────
    local data  = get_vnstat(iface_name)
    local iface = nil
    if data and data.interfaces then
        for _, v in ipairs(data.interfaces) do
            if v.name == iface_name then iface = v; break end
        end
    end

    if not iface then
        cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        set_col(cr, COL.div)
        dl(cr, M, 36, "no data")
        cairo_destroy(cr); cairo_surface_destroy(cs); return
    end

    -- ── accumulate period totals ──────────────────────────────────────────
    local today, wstart = week_range()
    local today_n  = date_num(today)
    local wstart_n = date_num(wstart)

    local day_rx, day_tx = 0, 0
    for _, d in ipairs(iface.traffic.day or {}) do
        if date_num(d.date) == today_n then
            day_rx = d.rx or 0; day_tx = d.tx or 0; break
        end
    end

    local week_rx, week_tx = 0, 0
    for _, d in ipairs(iface.traffic.day or {}) do
        local n = date_num(d.date)
        if n >= wstart_n and n <= today_n then
            week_rx = week_rx + (d.rx or 0)
            week_tx = week_tx + (d.tx or 0)
        end
    end

    local mon_rx, mon_tx = 0, 0
    for _, m in ipairs(iface.traffic.month or {}) do
        if m.date.year == today.year and m.date.month == today.month then
            mon_rx = m.rx or 0; mon_tx = m.tx or 0; break
        end
    end

    -- ── data rows ─────────────────────────────────────────────────────────
    local rows = {
        { "Today", day_rx,  day_tx  },
        { "Week",  week_rx, week_tx },
        { "Month", mon_rx,  mon_tx  },
    }

    cairo_set_font_size(cr, 10)
    local y = 50
    for _, row in ipairs(rows) do
        local lbl, rx, tx = row[1], row[2], row[3]

        cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        set_col(cr, COL.white)
        dl(cr, M, y, lbl)

        cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        set_col(cr, COL.tx)
        dr(cr, XUP, y, fmt_compact(tx))
        set_col(cr, COL.rx)
        dr(cr, XR,  y, fmt_compact(rx))

        y = y + 15
    end

    -- ── separator 2 ───────────────────────────────────────────────────────
    local Y_S2 = y - 8
    set_col(cr, COL.div, 0.6)
    cairo_move_to(cr, M,  Y_S2)
    cairo_line_to(cr, XR, Y_S2)
    cairo_stroke(cr)

    -- ── footer: two-color right-aligned "updated: <time>" ─────────────────
    local Y_F = Y_S2 + 12
    local ts  = os.date("%I:%M %p"):lower()
    cairo_set_font_size(cr, 9)

    cairo_select_font_face(cr, "Roboto", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    local ts_w = adv(cr, ts)
    set_col(cr, COL.white)
    cairo_move_to(cr, XR - ts_w, Y_F)
    cairo_show_text(cr, ts)

    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    local lbl_w = adv(cr, "updated: ")
    set_col(cr, COL.head)
    cairo_move_to(cr, XR - ts_w - lbl_w, Y_F)
    cairo_show_text(cr, "updated: ")

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
