-- gcal.lua - 150px narrow agenda view of gcalcli output
-- Stacked layout: title (word-wrapped) → time·length → location
-- v1 2026-07-04 @rew62

require 'cairo'
pcall(require, 'cairo_xlib')  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local FONT    = "Roboto"
local SZ_HDR  = 9
local SZ_EVT  = 9
local SZ_META = 8

local C_HDR    = {0.67, 0.84, 1.00, 1.0}
local C_DIV    = {0.40, 0.60, 0.85, 0.55}
local C_BULLET = {0.75, 0.90, 1.00, 0.85}
local C_EVT    = {1.00, 1.00, 1.00, 0.90}
local C_META   = {0.67, 0.84, 1.00, 0.70}
local C_LOC    = {0.67, 0.84, 1.00, 0.50}

local W       = 154     -- actual window width (minimum_width 150 + border_inner_margin*2)
local X       = 7
local Y_START = 16
local LINE_H  = 14
local HDR_H   = 20
local BX      = X + 5   -- bullet dot center x
local TX      = X + 13  -- event text left edge
local TW      = W - TX - 5  -- max text width (~127px)

local _cache = { days = nil, height = 0 }

-- ── helpers ──────────────────────────────────────────────────────────────────

local function set_color(cr, c)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], c[4])
end

local function set_font(cr, sz, bold)
    cairo_select_font_face(cr, FONT, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, sz)
end

local function measure_w(cr, sz, txt)
    set_font(cr, sz, false)
    local te = cairo_text_extents_t:create(); tolua.takeownership(te)
    cairo_text_extents(cr, txt, te)
    return te.x_advance
end

local function wrap(cr, sz, txt, max_w)
    local words = {}
    for w in txt:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return {""} end
    local lines, cur = {}, ""
    for _, word in ipairs(words) do
        local test = cur == "" and word or (cur .. " " .. word)
        if measure_w(cr, sz, test) <= max_w then
            cur = test
        else
            if cur ~= "" then lines[#lines + 1] = cur end
            cur = word
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end

-- Draw word-wrapped text. y = baseline of first line. Returns line count.
local function draw_wrapped(cr, sz, color, x, y, txt, max_w)
    set_color(cr, color)
    set_font(cr, sz, false)
    local lines = wrap(cr, sz, txt, max_w)
    for i, line in ipairs(lines) do
        cairo_move_to(cr, x, y + (i - 1) * LINE_H)
        cairo_show_text(cr, line)
    end
    return #lines
end

local function draw_divider(cr, y)
    set_color(cr, C_DIV)
    cairo_set_line_width(cr, 0.6)
    cairo_move_to(cr, X, y)
    cairo_line_to(cr, W - X, y)
    cairo_stroke(cr)
end

local function draw_bullet(cr, x, y)
    set_color(cr, C_BULLET)
    cairo_arc(cr, x, y, 2.2, 0, 2 * math.pi)
    cairo_fill(cr)
end

-- ── gcalcli parser ────────────────────────────────────────────────────────────

local function strip_ansi(s)
    return s:gsub("\027%[[%d;]*%a", "")
end

local function parse_date_label(raw)
    raw = raw:match("^%s*(.-)%s*$")
    if raw == "" then return nil end
    if not raw:match("^%a%a%a,? %a%a%a %d") then return nil end

    local upper = raw:upper()
    local m_name, d_num = upper:match("^%a%a%a,?%s+(%a%a%a)%s+(%d+)")
    local months = {
        JAN=1, FEB=2, MAR=3, APR=4,  MAY=5,  JUN=6,
        JUL=7, AUG=8, SEP=9, OCT=10, NOV=11, DEC=12
    }
    if m_name and d_num and months[m_name] then
        local now = os.date("*t")
        local m, d = months[m_name], tonumber(d_num)
        local y = now.year
        if now.month == 12 and m == 1 then y = y + 1 end
        local hts = os.time({year=y, month=m, day=d, hour=12})
        local tts = os.time({year=now.year, month=now.month, day=now.day, hour=12})
        local diff = math.floor((hts - tts) / 86400 + 0.5)
        -- Compact: "MON APR  6" or "MON APR  6  +3d"
        local base = string.format("%s %s %2d", upper:sub(1, 3), m_name, d)
        if diff > 0 then
            return string.format("%s  +%dd", base, diff)
        end
        return base
    end
    return upper
end

local function run_gcalcli()
    local f = io.popen("gcalcli agenda today '14 days' --details location --details length")
    if not f then return "" end
    local raw = f:read("*a")
    f:close()
    return raw
end

local function parse(raw)
    local days = {}
    local current, last_event = nil, nil

    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        local clean = strip_ansi(line)
        local left  = clean:sub(1, 12):match("^%s*(.-)%s*$")
        local right = clean:sub(13):match("^%s*(.-)%s*$")

        if right == "" and left == "" then
            -- blank line

        elseif right:match("^Length:") then
            if last_event then
                local val = right:match("^Length:%s*(.+)$") or ""
                local ndays = val:match("^(%d+) days?")
                if ndays then
                    if tonumber(ndays) > 1 then last_event.time = ndays .. "d" end
                else
                    last_event.length = val:gsub(":00$", "")
                end
            end

        elseif right:match("^Location:") then
            if last_event then
                last_event.location = right:match("^Location:%s*(.+)$") or ""
            end

        elseif left:match("^%d") and not left:match("%d+:%d+") then
            -- wrapped location continuation line — skip

        elseif left ~= "" and not left:match("^%d") then
            local date_str = parse_date_label(left)
            if date_str then
                current    = { header = date_str, events = {} }
                last_event = nil
                table.insert(days, current)
                if right ~= "" then
                    local t, title = right:match("^(%d+:%d+%a*)%s+(.*)")
                    last_event = {
                        text = title and title:match("^%s*(.-)%s*$") or right,
                        time = t or "", length = "", location = "",
                    }
                    table.insert(current.events, last_event)
                end
            end

        else
            if current and right ~= "" then
                local t, title = right:match("^(%d+:%d+%a*)%s+(.*)")
                last_event = {
                    text = title and title:match("^%s*(.-)%s*$") or right,
                    time = t or "", length = "", location = "",
                }
                table.insert(current.events, last_event)
            end
        end
    end
    return days
end

-- ── height estimation (no Cairo context needed) ───────────────────────────────

-- Rough char-based line count; avg Roboto glyph ≈ sz × 0.55 px wide.
local function approx_lines(txt, sz)
    local cpw = math.max(1, math.floor(TW / (sz * 0.55)))
    local words = {}
    for w in txt:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return 1 end
    local lines, cur = 1, 0
    for _, word in ipairs(words) do
        local wl = #word
        if cur == 0 then
            cur = wl
        elseif cur + 1 + wl > cpw then
            lines = lines + 1
            cur = wl
        else
            cur = cur + 1 + wl
        end
    end
    return lines
end

local function compute_height(days)
    local y = Y_START
    for _, day in ipairs(days) do
        y = y + 4 + 2 + 4  -- gap-above-divider + divider + gap-below
        y = y + HDR_H
        for _, ev in ipairs(day.events) do
            y = y + approx_lines(ev.text, SZ_EVT) * LINE_H
            if ev.time ~= "" then y = y + LINE_H end
            if ev.location ~= "" then
                y = y + approx_lines(ev.location, SZ_META) * LINE_H
            end
            y = y + 3
        end
        y = y + 4
    end
    return y
end

function gcal_prefetch()
    local raw     = run_gcalcli()
    _cache.days   = parse(raw)
    _cache.height = compute_height(_cache.days)
    return _cache.height
end

-- ── main draw ─────────────────────────────────────────────────────────────────

function conky_draw_gcal()
    if conky_window == nil then return end

    local cs = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable,
        conky_window.visual, conky_window.width, conky_window.height)
    local cr = cairo_create(cs)

    local days = _cache.days or parse(run_gcalcli())
    local y = Y_START

    for _, day in ipairs(days) do
        -- Divider above date header
        y = y + 4
        draw_divider(cr, y)
        y = y + 2 + 4

        -- Date header (bold)
        set_color(cr, C_HDR)
        set_font(cr, SZ_HDR, true)
        cairo_move_to(cr, X, y + SZ_HDR)
        cairo_show_text(cr, day.header)
        y = y + HDR_H

        for _, ev in ipairs(day.events) do
            -- Bullet at vertical center of first title line
            draw_bullet(cr, BX, y + SZ_EVT / 2)

            -- Event title (word-wrapped)
            local ntitle = draw_wrapped(cr, SZ_EVT, C_EVT, TX, y + SZ_EVT, ev.text, TW)
            y = y + ntitle * LINE_H

            -- Meta: time  ·  length (dimmer, smaller)
            if ev.time ~= "" then
                local meta = ev.length ~= "" and (ev.time .. "  " .. ev.length) or ev.time
                set_color(cr, C_META)
                set_font(cr, SZ_META, false)
                cairo_move_to(cr, TX, y + SZ_META)
                cairo_show_text(cr, meta)
                y = y + LINE_H
            end

            -- Location (dimmest, word-wrapped)
            if ev.location ~= "" then
                local nloc = draw_wrapped(cr, SZ_META, C_LOC, TX, y + SZ_META, ev.location, TW)
                y = y + nloc * LINE_H
            end

            y = y + 3  -- breathing room between events
        end

        y = y + 4  -- spacing after day group
    end

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
