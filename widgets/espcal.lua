-- espcal.lua — sidepanel calendar widget (pure Lua / Cairo)
--
-- Replaces sidepanel-calendar.rc.  All rendering is Cairo; conky.text is empty.
-- Self-contained: conky runs this same file once directly (as the -c config,
-- before lua_load fires) and once via its own lua_load, so it bootstraps its
-- own package.path/try_require rather than depending on scripts/loadall.lua,
-- which hasn't run yet on that first pass.
--
-- Layout (top → bottom, 150 × 150 px):
--   Month name  (Good Times 14pt, month color, centered)
--   DOW header  (S M T W T F S, 10pt, today bold-white + highlight box)
--   Large date  (Metropolis 38pt, GreenYellow, centered)
--   Time        (GE Inspira 22pt + 15pt a/p, khaki, centered as unit)
--   Moon icon   (left, MonaspiceNe 20pt, phase color)
--   Zodiac      (right, glyph 18pt + name 9pt, right-aligned)
--
-- Controls: Ctrl+left-click → save position; Ctrl+right-click → kill widget.
-- v1 2026-07-04 @rew62

if not conky then require 'cairo'; pcall(require, 'cairo_xlib') end  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local _dir = debug.getinfo(1,'S').source:match("@?(.*/)") or "./"
package.path = _dir.."?.lua;".._dir.."../scripts/?.lua;"..package.path
    .. ";" .. (os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma") .. "/scripts/?.lua"

local function try_require(mod)
    local ok, result = pcall(require, mod)
    if not ok then
        print("[enigma] failed to load " .. mod .. ": " .. tostring(result))
        os.exit(1)
    end
    return result
end

try_require("draw_bg")
local window  = try_require("window")
local surface = try_require("surface")

-- Apply WIDGET_CONFIG globals (mirrors loadall.lua dispatch; espcal is self-contained and skips loadall)
do
    local _wc = (WIDGET_CONFIG and WIDGET_CONFIG["espcal.lua"]) or {}
    for k, v in pairs(_wc.globals or {}) do _G[k] = v end
end

divider       = "top,bottom"
divider_color = 0xf2f2f2
divider_alpha = 0.35
divider_width = 1

-- ── helpers ──────────────────────────────────────────────────────────────────
local function hex_to_rgb(h)
    return tonumber(h:sub(1,2),16)/255,
           tonumber(h:sub(3,4),16)/255,
           tonumber(h:sub(5,6),16)/255
end

local MONTH_HEX = {
    "E57373","F06292","BA68C8","9575CD",
    "7986CB","64B5F6","4DD0E1","4DB6AC",
    "81C784","AED581","FFB74D","A1887F",
}

-- ── layout ───────────────────────────────────────────────────────────────────
-- DOW: %u → 1=Mon … 7=Sun.  Display order S M T W T F S.
-- x values = original ${goto} values + border_inner_margin(2) → window coords.
local DOW_X    = { [7]=9,[1]=30,[2]=52,[3]=73,[4]=94,[5]=116,[6]=137 }
local DOW_CHAR = { [7]="S",[1]="M",[2]="T",[3]="W",[4]="T",[5]="F",[6]="S" }
local DOW_ORDER= { 7,1,2,3,4,5,6 }   -- Sun Mon Tue Wed Thu Fri Sat

-- All font sizes are px = pt × 96/72 to match conky Xft rendering.
-- Content shifted down 15px from top; moon/zodiac pulled up 20px from that.
local Y_DOW    = 28    -- DOW header baseline     (15px)
local Y_DATE   = 76    -- large date baseline     (51px = 38pt)
local Y_MONTH  = 104   -- month name baseline     (19px = 14pt)
local Y_TIME   = 137   -- time baseline           (29px = 22pt)
local Y_MOON   = 142   -- moon baseline
local Y_BOT    = 140   -- zodiac baseline

local DOW_BOX_Y = 14   -- highlight box top (baseline 28 - ascent ~12)
local DOW_BOX_H = 16
local DOW_BOX_W = 14

-- ── zodiac ───────────────────────────────────────────────────────────────────
local ZODIAC = {
    { sym="♑", name="Capricorn",   sm=12, sd=22, em= 1, ed=19 },
    { sym="♒", name="Aquarius",    sm= 1, sd=20, em= 2, ed=18 },
    { sym="♓", name="Pisces",      sm= 2, sd=19, em= 3, ed=20 },
    { sym="♈", name="Aries",       sm= 3, sd=21, em= 4, ed=19 },
    { sym="♉", name="Taurus",      sm= 4, sd=20, em= 5, ed=20 },
    { sym="♊", name="Gemini",      sm= 5, sd=21, em= 6, ed=20 },
    { sym="♋", name="Cancer",      sm= 6, sd=21, em= 7, ed=22 },
    { sym="♌", name="Leo",         sm= 7, sd=23, em= 8, ed=22 },
    { sym="♍", name="Virgo",       sm= 8, sd=23, em= 9, ed=22 },
    { sym="♎", name="Libra",       sm= 9, sd=23, em=10, ed=22 },
    { sym="♏", name="Scorpio",     sm=10, sd=23, em=11, ed=21 },
    { sym="♐", name="Sagittarius", sm=11, sd=22, em=12, ed=21 },
}

local function current_sign()
    local d = tonumber(os.date("%d"))
    local m = tonumber(os.date("%m"))
    for _, z in ipairs(ZODIAC) do
        if (m == z.sm and d >= z.sd) or (m == z.em and d <= z.ed) then
            return z
        end
    end
end

-- ── moon phase ────────────────────────────────────────────────────────────────
local MOON_FONT = "MonaspiceNe Nerd Font Mono"

local function moon_phase_data()
    local lp    = 2551443
    local phase = ((os.time() - os.time{year=2001,month=1,day=24,hour=13,min=46}) % lp) / lp

    local NEW   = "\u{E3D5}"
    local CRES  = {"\u{E38E}","\u{E38F}","\u{E390}","\u{E391}","\u{E392}","\u{E393}"}
    local FIRST = "\u{E394}"
    local GIB   = {"\u{E395}","\u{E396}","\u{E397}","\u{E398}","\u{E399}","\u{E39A}"}
    local FULL  = "\u{E39B}"
    local WGIB  = {"\u{E39C}","\u{E39D}","\u{E39E}","\u{E39F}","\u{E3A0}","\u{E3A1}"}
    local LAST  = "\u{E3A2}"
    local WCRES = {"\u{E3A3}","\u{E3A4}","\u{E3A5}","\u{E3A6}","\u{E3A7}","\u{E3A8}"}

    local function idx(base, lo, hi)
        return math.min(math.floor((phase-lo)/(hi-lo)*6)+1, 6)
    end

    if     phase < 0.02 or phase >= 0.98 then return NEW,  "546E7A"
    elseif phase < 0.23 then return CRES [idx(CRES,  0.02,0.23)], "B0BEC5"
    elseif phase < 0.27 then return FIRST,                          "81D4FA"
    elseif phase < 0.48 then return GIB  [idx(GIB,   0.27,0.48)], "E0E0E0"
    elseif phase < 0.52 then return FULL,                           "FFF59D"
    elseif phase < 0.73 then return WGIB [idx(WGIB,  0.52,0.73)], "E0E0E0"
    elseif phase < 0.77 then return LAST,                           "81D4FA"
    else                      return WCRES[idx(WCRES, 0.77,0.98)], "B0BEC5"
    end
end

function conky_mouse_hook(event)
    if WINDOW_MOUSE_HOOK == false then return false end
    return window.handle_mouse(event)
end

-- ── main draw ─────────────────────────────────────────────────────────────────
function conky_draw_espcal()
    if conky_window == nil then return end

    draw_bg()

    log_window_size()

    local cw    = conky_window
    local w, h  = cw.width, cw.height
    local cs, owns = surface.get()
    if cs == nil then return end
    local cr    = cairo_create(cs)

    local now    = os.date("*t")
    local dow    = tonumber(os.date("%u"))   -- 1=Mon … 7=Sun
    local mr, mg, mb = hex_to_rgb(MONTH_HEX[now.month])
    local hour12 = tonumber(os.date("%I"))   -- 01-12 → number strips zero
    local tstr   = string.format("%d:%02d", hour12, now.min)
    local ampm   = now.hour < 12 and "a" or "p"

    -- ── DOW highlight box: measure today's letter to center it exactly ────────
    local bx = DOW_X[dow]
    if bx then
        cairo_select_font_face(cr, "DejaVuSansM Nerd Font Propo",
            CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, 15)
        local le = cairo_text_extents_t:create(); tolua.takeownership(le)
        cairo_text_extents(cr, DOW_CHAR[dow], le)
        local cx    = bx + le.x_bearing + le.width / 2
        local box_w = math.ceil(le.width) + 8   -- 4px padding each side
        cairo_set_source_rgba(cr, 0.596, 0.984, 0.596, 0.40)   -- #98FB98 @ 40%
        cairo_rectangle(cr, math.floor(cx - box_w/2) + 1, DOW_BOX_Y, box_w, DOW_BOX_H)
        cairo_fill(cr)
    end

    -- ── DOW row: S M T W T F S (top) ─────────────────────────────────────────
    for _, d in ipairs(DOW_ORDER) do
        if d == dow then
            cairo_set_source_rgba(cr, 0xEC/255, 0xF0/255, 0xF1/255, 1.0)   -- white
            cairo_select_font_face(cr, "DejaVuSansM Nerd Font Propo",
                CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        else
            cairo_set_source_rgba(cr, 0x98/255, 0xFB/255, 0x98/255, 1.0)   -- PaleGreen
            cairo_select_font_face(cr, "DejaVuSansM Nerd Font Propo",
                CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        end
        cairo_set_font_size(cr, 15)
        cairo_move_to(cr, DOW_X[d], Y_DOW)
        cairo_show_text(cr, DOW_CHAR[d])
    end

    -- ── Large date number (Metropolis 51px = 38pt, GreenYellow, centered) ────
    cairo_select_font_face(cr, "Metropolis", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 51)   -- 38pt × 96/72
    cairo_set_source_rgba(cr, 0xAD/255, 0xFF/255, 0x2F/255, 1.0)   -- ADFF2F GreenYellow
    local de  = cairo_text_extents_t:create(); tolua.takeownership(de)
    local dstr = tostring(now.day)
    cairo_text_extents(cr, dstr, de)
    cairo_move_to(cr, math.floor(w/2 - de.x_advance/2), Y_DATE)
    cairo_show_text(cr, dstr)

    -- ── Month name (Good Times 19px = 14pt, month color, centered) ───────────
    cairo_select_font_face(cr, "Good Times", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 19)   -- 14pt × 96/72
    cairo_set_source_rgba(cr, mr, mg, mb, 1.0)
    local me = cairo_text_extents_t:create(); tolua.takeownership(me)
    local mstr = os.date("%B")
    cairo_text_extents(cr, mstr, me)
    cairo_move_to(cr, math.floor(w/2 - me.x_advance/2), Y_MONTH)
    cairo_show_text(cr, mstr)

    -- ── Time (GE Inspira 29px = 22pt main + 20px = 15pt a/p, khaki) ──────────
    cairo_set_source_rgba(cr, 0xF0/255, 0xE6/255, 0x8C/255, 1.0)   -- F0E68C khaki
    cairo_select_font_face(cr, "GE Inspira", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 29)   -- 22pt × 96/72
    local te1 = cairo_text_extents_t:create(); tolua.takeownership(te1)
    cairo_text_extents(cr, tstr, te1)
    cairo_set_font_size(cr, 20)   -- 15pt × 96/72
    local te2 = cairo_text_extents_t:create(); tolua.takeownership(te2)
    cairo_text_extents(cr, ampm, te2)
    local tx = math.floor(w/2 - (te1.x_advance + te2.x_advance) / 2)
    cairo_set_font_size(cr, 29)
    cairo_move_to(cr, tx, Y_TIME); cairo_show_text(cr, tstr)
    cairo_set_font_size(cr, 20)
    cairo_move_to(cr, tx + te1.x_advance, Y_TIME); cairo_show_text(cr, ampm)

    -- ── Moon icon (bottom LEFT, MonaspiceNe 27px, phase color) ───────────────
    local sym, col = moon_phase_data()
    local mr2, mg2, mb2 = hex_to_rgb(col)
    cairo_select_font_face(cr, MOON_FONT, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 24)
    cairo_set_source_rgba(cr, mr2, mg2, mb2, 0.90)
    cairo_move_to(cr, 6, Y_MOON)
    cairo_show_text(cr, sym)

    -- ── Zodiac glyph (bottom RIGHT, 27px, right-aligned) ─────────────────────
    local z = current_sign()
    if z then
        cairo_select_font_face(cr, "DejaVu Sans Mono", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 20)
        local zge = cairo_text_extents_t:create(); tolua.takeownership(zge)
        cairo_text_extents(cr, z.sym, zge)
        cairo_set_source_rgba(cr, 0xD0/255, 0xB8/255, 0xE8/255, 0.90)   -- light purple
        cairo_move_to(cr, w - 4 - zge.x_advance, Y_BOT)
        cairo_show_text(cr, z.sym)
    end

    -- ── top + bottom dividers (shared draw_dividers from scripts/draw_bg.lua) ──
    draw_dividers(cr, w, h)

    cairo_destroy(cr)
    surface.put(cs, owns)
end

-- ─────────────────────────────────────────────────────────────────────────────

if conky then
    local HOME       = os.getenv("HOME") or ""
    local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (HOME .. "/.conky/enigma")

    conky.config = {
        alignment            = 'top_right',
        gap_x                = 5,
        gap_y                = 50,
        minimum_width        = 150,
        maximum_width        = 150,
        minimum_height       = 145,

        own_window             = true,
        own_window_type        = 'normal',
        own_window_title       = 'espcal',
        own_window_hints       = 'undecorated,below,sticky,skip_taskbar,skip_pager',
        own_window_argb_visual = true,
        own_window_argb_value  = 0,
        own_window_colour      = '000000',
        double_buffer          = true,
        draw_shades            = false,
        draw_outline           = false,
        draw_borders           = false,
        border_inner_margin    = 2,
        border_outer_margin    = 0,
        border_width           = 0,

        use_xft              = true,
        override_utf8_locale = true,

        -- color palette (reference; used directly in Cairo above)
        default_color = '8FBC8F',
        color1 = '98FB98',  -- PaleGreen  (DOW normal)
        color2 = '2E8B57',  -- SeaGreen
        color3 = 'ADFF2F',  -- GreenYellow (large date)
        color4 = 'ECF0F1',  -- white       (today DOW)
        color5 = 'F0E68C',  -- khaki       (time)
        color6 = '006400',
        color7 = 'FFD500',  -- Ukraine Yellow
        color8 = '005BBB',  -- Ukraine Blue

        update_interval = 10,
        total_run_times = 0,

        lua_load           = ENIGMA_DIR .. '/settings.lua ./espcal.lua',
        lua_startup_hook   = 'vars',
        lua_draw_hook_post = 'draw_espcal',
        lua_mouse_hook     = 'mouse_hook',
    }
    conky.text = [[]]
end
