-- nsd2.lua – combo always-on + selectable graph below (Net / Sys / Disk)
-- Left-click cycles graph: net → sys → disk → net
-- Ctrl+left-click saves window position; Ctrl+right-click kills instance.
-- v1 2026-07-04 @rew62

if not conky then require 'cairo' end

local _dir       = debug.getinfo(1, 'S').source:match("@?(.*/)") or "./"
local HOME       = os.getenv("HOME") or ""
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (HOME .. "/.conky/enigma")

package.path = _dir .. "?.lua;"
    .. ENIGMA_DIR .. "/scripts/?.lua;"
    .. ENIGMA_DIR .. "/widgets/?.lua;"
    .. package.path

local function read_env(key, fallback)
    local f = io.open(ENIGMA_DIR .. "/.env", "r")
    if f then
        for line in f:lines() do
            local v = line:match("^" .. key .. "=(.+)$")
            if v then f:close(); return v:gsub('"', ''):gsub("'", "") end
        end
        f:close()
    end
    return fallback
end

-- ── State ─────────────────────────────────────────────────────────────────────

local VIEW_ORDER = { "net", "sys", "disk" }
local view_idx   = 1
local DISK_DEV   = read_env("DISK_DEV", "nvme0n1")
local NET_IFACE  = read_env("INTERFACE_NAME", "wlp2s0")

-- ── Module loading ────────────────────────────────────────────────────────────

local window, net, sys, disk

if not conky then
    local function try_req(mod)
        local ok, r = pcall(require, mod)
        if not ok then print("[nsd2] cannot load " .. mod .. ": " .. r); os.exit(1) end
        return r
    end
    try_req("draw_bg")
    window = try_req("window")
    net    = try_req("net")
    sys    = try_req("sys")
    disk   = try_req("disk")
    divider = "top,bottom"
end

-- ── Colors ────────────────────────────────────────────────────────────────────

local CO_HEAD  = { 0x2D/255, 0x9E/255, 0xEA/255 }
local CO_WHITE = { 0xe8/255, 0xe8/255, 0xe8/255 }
local CO_LINE  = { 0.38, 0.56, 0.88 }
local CO_DN     = { 0x9e/255, 0xd1/255, 0xff/255 }  -- matches net graph's DOWN color
local CO_ORANGE = { 0xE8/255, 0xA0/255, 0x60/255 }  -- matches DISK graph label color
local CO_TEMP_LO, CO_TEMP_HI = 30, 95

-- graph label row: glyph (DejaVuSansM Nerd Font Propo), name, color
-- glyphs: U+F0002 network, U+F061A system/memory, U+F02CA disk
local GRAPH_LABELS = {
    { glyph = "\xF3\xB0\x80\x82", name = "NETWORK",
      c = { 0x98/255, 0xFB/255, 0x98/255 } },   -- alien green
    { glyph = "\xF3\xB0\x98\x9A", name = "SYSTEM",
      c = { 0xD0/255, 0xB8/255, 0xE8/255 } },   -- alien purple
    { glyph = "\xF3\xB0\x8B\x8A", name = "DISK",
      c = { 0xE8/255, 0xA0/255, 0x60/255 } },   -- orange
}

-- ── Hex maze icon (enigma-logo2 maze portion, no text, no background clear) ───
-- SVG dimensions from enigma-logo2.lua; maze paths end at ~Y(180).

local SVG_W = 210.02
local SVG_H = 219.95

local function draw_hex_maze(cr, ix, iy, iw, ih)
    local function X(x) return ix + x * iw / SVG_W end
    local function Y(y) return iy + y * ih / SVG_H end
    cairo_set_source_rgb(cr, 0x98/255, 0xFB/255, 0x98/255)
    cairo_move_to(cr, X(73.657), Y(39.97))
    cairo_line_to(cr, X(104.99), Y(21.882))
    cairo_line_to(cr, X(104.99), Y(15.101))
    cairo_line_to(cr, X(75.513), Y(32.138))
    cairo_line_to(cr, X(68.973), Y(20.753))
    cairo_line_to(cr, X(27.065), Y(44.897))
    cairo_line_to(cr, X(27.065), Y(134.93))
    cairo_line_to(cr, X(32.88),  Y(131.54))
    cairo_line_to(cr, X(32.88),  Y(48.287))
    cairo_line_to(cr, X(67.116), Y(28.585))
    cairo_close_path(cr)
    cairo_move_to(cr, X(104.99), Y(173.21))
    cairo_line_to(cr, X(76.645), Y(156.81))
    cairo_line_to(cr, X(80.277), Y(150.52))
    cairo_line_to(cr, X(104.99), Y(164.73))
    cairo_line_to(cr, X(104.99), Y(158.03))
    cairo_line_to(cr, X(46.041), Y(123.95))
    cairo_line_to(cr, X(46.041), Y(91.005))
    cairo_line_to(cr, X(53.389), Y(91.005))
    cairo_line_to(cr, X(53.389), Y(119.75))
    cairo_line_to(cr, X(59.284), Y(116.36))
    cairo_line_to(cr, X(59.284), Y(85.19))
    cairo_line_to(cr, X(46.041), Y(85.19))
    cairo_line_to(cr, X(46.041), Y(55.878))
    cairo_line_to(cr, X(40.228), Y(52.486))
    cairo_line_to(cr, X(40.228), Y(127.34))
    cairo_line_to(cr, X(75.513), Y(147.69))
    cairo_line_to(cr, X(69.862), Y(157.62))
    cairo_line_to(cr, X(68.973), Y(159.16))
    cairo_line_to(cr, X(104.99), Y(179.99))
    cairo_line_to(cr, X(182.99), Y(134.93))
    cairo_line_to(cr, X(177.17), Y(131.54))
    cairo_close_path(cr)
    cairo_move_to(cr, X(104.99), Y(52.325))
    cairo_line_to(cr, X(137.61), Y(71.139))
    cairo_line_to(cr, X(143.5),  Y(67.749))
    cairo_line_to(cr, X(104.99), Y(45.542))
    cairo_line_to(cr, X(83.912), Y(57.735))
    cairo_line_to(cr, X(90.452), Y(69.121))
    cairo_line_to(cr, X(79.793), Y(75.338))
    cairo_line_to(cr, X(79.793), Y(104.49))
    cairo_line_to(cr, X(104.99), Y(119.1))
    cairo_line_to(cr, X(130.26), Y(104.49))
    cairo_line_to(cr, X(124.45), Y(101.1))
    cairo_line_to(cr, X(104.99), Y(112.32))
    cairo_line_to(cr, X(85.608), Y(101.1))
    cairo_line_to(cr, X(85.608), Y(78.731))
    cairo_line_to(cr, X(104.99), Y(67.506))
    cairo_line_to(cr, X(124.45), Y(78.731))
    cairo_line_to(cr, X(124.45), Y(85.19))
    cairo_line_to(cr, X(104.74), Y(85.19))
    cairo_line_to(cr, X(104.74), Y(91.005))
    cairo_line_to(cr, X(130.26), Y(91.005))
    cairo_line_to(cr, X(130.26), Y(75.338))
    cairo_line_to(cr, X(104.99), Y(60.723))
    cairo_line_to(cr, X(95.297), Y(66.377))
    cairo_line_to(cr, X(91.584), Y(60.078))
    cairo_close_path(cr)
    cairo_move_to(cr, X(104.99), Y(142.76))
    cairo_line_to(cr, X(84.962), Y(131.14))
    cairo_line_to(cr, X(82.054), Y(136.22))
    cairo_line_to(cr, X(104.99), Y(149.55))
    cairo_line_to(cr, X(133.98), Y(132.75))
    cairo_line_to(cr, X(127.35), Y(121.45))
    cairo_line_to(cr, X(143.5),  Y(112.16))
    cairo_line_to(cr, X(143.5),  Y(91.004))
    cairo_line_to(cr, X(137.61), Y(91.004))
    cairo_line_to(cr, X(137.61), Y(108.77))
    cairo_line_to(cr, X(104.99), Y(127.58))
    cairo_line_to(cr, X(72.445), Y(108.77))
    cairo_line_to(cr, X(72.445), Y(71.14))
    cairo_line_to(cr, X(66.552), Y(67.748))
    cairo_line_to(cr, X(66.552), Y(112.16))
    cairo_line_to(cr, X(104.99), Y(134.29))
    cairo_line_to(cr, X(122.59), Y(124.19))
    cairo_line_to(cr, X(126.3),  Y(130.49))
    cairo_close_path(cr)
    cairo_move_to(cr, X(156.66), Y(119.75))
    cairo_line_to(cr, X(156.66), Y(60.159))
    cairo_line_to(cr, X(104.99), Y(30.28))
    cairo_line_to(cr, X(53.389), Y(60.159))
    cairo_line_to(cr, X(59.285), Y(63.469))
    cairo_line_to(cr, X(104.99), Y(37.064))
    cairo_line_to(cr, X(150.77), Y(63.469))
    cairo_line_to(cr, X(150.77), Y(116.36))
    cairo_close_path(cr)
    cairo_move_to(cr, X(131.8),  Y(37.305))
    cairo_line_to(cr, X(164.01), Y(55.877))
    cairo_line_to(cr, X(164.01), Y(123.95))
    cairo_line_to(cr, X(132.93), Y(141.88))
    cairo_line_to(cr, X(135.83), Y(146.96))
    cairo_line_to(cr, X(169.83), Y(127.34))
    cairo_line_to(cr, X(169.83), Y(52.487))
    cairo_line_to(cr, X(139.47), Y(34.964))
    cairo_line_to(cr, X(143.1),  Y(28.585))
    cairo_line_to(cr, X(177.18), Y(48.288))
    cairo_line_to(cr, X(182.99), Y(44.896))
    cairo_line_to(cr, X(105.23), Y(0))
    cairo_line_to(cr, X(105.23), Y(6.7827))
    cairo_line_to(cr, X(138.34), Y(25.839))
    cairo_close_path(cr)
    cairo_fill(cr)
end

-- ── Net speed formatter ───────────────────────────────────────────────────────

local function co_net_fmt(v)
    local kbs = tonumber(v) or 0
    if     kbs >= 1024 then return string.format("%.1fM", kbs / 1024)
    elseif kbs >= 1    then return string.format("%.1fk", kbs)
    else                    return "0b" end
end

-- ── Network graph header (Qual/TCP + Up/Dn, matches sys/disk header style) ────

local HDR_M  = 4
local HDR_LV = 72
local HDR_RL = 90
local HDR_R1 = 13
local HDR_R2 = 26

local function draw_net_header(cr, w)
    local xr = w - HDR_M
    local te = cairo_text_extents_t:create(); tolua.takeownership(te)

    local function sc(c, a) cairo_set_source_rgba(cr, c[1], c[2], c[3], a or 1.0) end
    local function dl(x, y, s) cairo_move_to(cr, x, y); cairo_show_text(cr, s) end
    local function dr(x, y, s)
        cairo_text_extents(cr, s, te)
        cairo_move_to(cr, x - te.x_advance, y); cairo_show_text(cr, s)
    end
    local function gs(var) local v = conky_parse(var); return (v and v ~= "") and v or "--" end

    local essid   = conky_parse("${wireless_essid " .. NET_IFACE .. "}")
    local is_wifi = essid and essid ~= "" and essid ~= "off/any"
    local gw      = conky_parse("${gw_iface}") or NET_IFACE
    local iface   = is_wifi and NET_IFACE or gw

    cairo_set_font_size(cr, 10)

    local y = HDR_R1
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(HDR_M,  y, is_wifi and "Qual" or "GW")
    dl(HDR_RL, y, "TCP")
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(HDR_LV, y, is_wifi
        and (gs("${wireless_link_qual_perc " .. NET_IFACE .. "}") .. "%")
        or  "wired")
    dr(xr, y, gs("${tcp_portmon 1 32767 count}") .. "/"
           .. gs("${tcp_portmon 32768 61000 count}"))

    y = HDR_R2
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(HDR_M,  y, "Up")
    dl(HDR_RL, y, "Dn")
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(HDR_LV, y, co_net_fmt(gs("${upspeedf "   .. iface .. "}")))
    dr(xr, y, co_net_fmt(gs("${downspeedf " .. iface .. "}")))
end

-- ── Combo summary view (always visible) ───────────────────────────────────────

local function draw_combo(cr, w, h)
    local M  = 4
    local LV = 72
    local RL = 90
    local xr = w - M
    local te = cairo_text_extents_t:create(); tolua.takeownership(te)

    local function sc(c, a) cairo_set_source_rgba(cr, c[1], c[2], c[3], a or 1.0) end
    local function dl(x, y, s) cairo_move_to(cr, x, y); cairo_show_text(cr, s) end
    local function dr(x, y, s)
        cairo_text_extents(cr, s, te)
        cairo_move_to(cr, x - te.x_advance, y); cairo_show_text(cr, s)
    end
    local function sep(y)
        cairo_set_line_width(cr, 1)
        sc(CO_LINE, 0.35)
        cairo_move_to(cr, M, y); cairo_line_to(cr, w - M, y); cairo_stroke(cr)
    end
    local function gs(var) local v = conky_parse(var); return (v and v ~= "") and v or "--" end

    local TOPS = { 3, 62, 108 }

    -- ── NET ─────────────────────────────────────────────────────────────
    local y0    = TOPS[1]
    local essid = conky_parse("${wireless_essid " .. NET_IFACE .. "}")
    local is_wifi = essid and essid ~= "" and essid ~= "off/any"
    local gw    = conky_parse("${gw_iface}") or NET_IFACE
    local iface = is_wifi and NET_IFACE or gw

    -- row 1: hex maze icon | ssid / gw name
    draw_hex_maze(cr, M, y0, 13, 13)

    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(xr, y0 + 12, is_wifi and (essid or "--") or gw)

    -- row 2: IPs (small bold, matches net graph view)
    cairo_set_font_size(cr, 9)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_DN)
    dl(M,  y0 + 25, gs("${addr " .. iface .. "}"))
    sc(CO_ORANGE)
    dr(xr, y0 + 25, gs("${texeci 86400 curl -s https://api.ipify.org}"))

    -- row 3: Qual/GW | TCP ports
    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 38, is_wifi and "Qual" or "GW")
    dl(RL, y0 + 38, "TCP")
    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 38, is_wifi
        and (gs("${wireless_link_qual_perc " .. NET_IFACE .. "}") .. "%")
        or  "wired")
    dr(xr, y0 + 38, gs("${tcp_portmon 1 32767 count}") .. "/"
                 .. gs("${tcp_portmon 32768 61000 count}"))

    -- mid: Up / Dn speeds
    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 51, "Up")
    dl(RL, y0 + 51, "Dn")
    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 51, co_net_fmt(gs("${upspeedf "   .. iface .. "}")))
    dr(xr, y0 + 51, co_net_fmt(gs("${downspeedf " .. iface .. "}")))

    sep(TOPS[2] - 1)

    -- ── SYS ─────────────────────────────────────────────────────────────
    y0 = TOPS[2]

    local bat_f  = io.open("/sys/class/power_supply/BAT0/uevent", "r")
    local has_bat = bat_f ~= nil
    if bat_f then bat_f:close() end
    local r2_lbl, r2_val, r2_temp
    if has_bat then
        r2_lbl = "PWR"
        r2_val = gs("${battery_percent BAT0}") .. "%"
    else
        local raw = gs("${acpitemp}")
        r2_lbl    = "Temp"
        r2_val    = raw .. "\xc2\xb0"
        r2_temp   = tonumber(raw)
    end

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 12, "CPU")
    dl(RL, y0 + 12, "RAM")
    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 12, gs("${cpu cpu0}") .. "%")
    dr(xr, y0 + 12, gs("${memperc}") .. "%")

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 25, "Up")
    dl(RL, y0 + 25, r2_lbl)
    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 25, gs("${uptime_short}"))
    if r2_temp then
        local pct = math.max(0, math.min(1, (r2_temp - CO_TEMP_LO) / (CO_TEMP_HI - CO_TEMP_LO)))
        local function lerp(a, b, t) return a + (b - a) * t end
        local vr, vg, vb
        if pct < 0.5 then
            local t = pct / 0.5
            vr, vg, vb = lerp(0.30, 0.92, t), lerp(0.72, 0.76, t), lerp(1.00, 0.22, t)
        else
            local t = (pct - 0.5) / 0.5
            vr, vg, vb = lerp(0.92, 1.00, t), lerp(0.76, 0.18, t), lerp(0.22, 0.05, t)
        end
        cairo_set_source_rgba(cr, vr, vg, vb, 1.0)
    else
        sc(CO_WHITE)
    end
    dr(xr, y0 + 25, r2_val)

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 38, "CPU1")
    dl(RL, y0 + 38, "CPU2")
    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 38, gs("${cpu cpu1}") .. "%")
    dr(xr, y0 + 38, gs("${cpu cpu2}") .. "%")

    sep(TOPS[3] - 1)

    -- ── DISK ────────────────────────────────────────────────────────────
    y0 = TOPS[3]

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 12, "Disk")
    dl(RL, y0 + 12, "Used")
    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 12, gs("${fs_used_perc /}") .. "%")
    dr(xr, y0 + 12, gs("${fs_used /}"))

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 25, "Total")
    dl(RL, y0 + 25, "Free")
    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 25, gs("${fs_size /}"))
    dr(xr, y0 + 25, gs("${fs_free /}"))

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 38, "RD")
    dl(RL, y0 + 38, "WR")
    cairo_set_font_size(cr, 12)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 38, gs("${diskio_read "  .. DISK_DEV .. "}"))
    dr(xr, y0 + 38, gs("${diskio_write " .. DISK_DEV .. "}"))

    draw_dividers(cr, w, h)
end

-- ── Layout constants ──────────────────────────────────────────────────────────

local COMBO_SEP_Y = 156   -- divider between combo and graph label
local LABEL_Y     = 169   -- graph label row baseline
local GRAPH_Y     = 175   -- y-origin for graph section (cairo translate)

-- ── Conky hook functions ───────────────────────────────────────────────────────

function conky_nsd2_text()
    return ""
end

function conky_mouse_hook2(event)
    if window and window.handle_mouse(event) then return true end
    if event.type == "button_down" and event.button == "left" then
        view_idx = (view_idx % #VIEW_ORDER) + 1
        print("[nsd2] graph -> " .. VIEW_ORDER[view_idx])
        return true
    end
    return false
end

function conky_main2()
    if conky_window == nil then return end
    if conky_window.width == 0 or conky_window.height == 0 then return end

    draw_bg()

    log_window_size()

    local cs = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable,
        conky_window.visual,  conky_window.width, conky_window.height)
    local cr = cairo_create(cs)
    local w  = conky_window.width
    local h  = conky_window.height

    local essid = conky_parse("${wireless_essid " .. NET_IFACE .. "}")
    local iface = (essid and essid ~= "" and essid ~= "off/any")
        and NET_IFACE
        or  (conky_parse("${gw_iface}") or NET_IFACE)

    -- keep all graph histories warm regardless of current view
    net.update(iface)
    sys.update()
    disk.update(DISK_DEV)

    -- combo always on top; draw_dividers(cr,w,h) called inside for full widget borders
    draw_combo(cr, w, h)

    local lbl = GRAPH_LABELS[view_idx]

    -- section separator (color matches the active graph)
    cairo_set_line_width(cr, 1)
    cairo_set_source_rgba(cr, lbl.c[1], lbl.c[2], lbl.c[3], 0.6)
    cairo_move_to(cr, 4, COMBO_SEP_Y); cairo_line_to(cr, w - 4, COMBO_SEP_Y)
    cairo_stroke(cr)

    -- graph label row: glyph in graph color, name in matching color
    local te  = cairo_text_extents_t:create(); tolua.takeownership(te)

    cairo_select_font_face(cr, "DejaVuSansM Nerd Font Propo",
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 12)
    cairo_set_source_rgba(cr, lbl.c[1], lbl.c[2], lbl.c[3], 1.0)
    cairo_move_to(cr, 4, LABEL_Y)
    cairo_show_text(cr, lbl.glyph)
    cairo_text_extents(cr, lbl.glyph, te)
    local name_x = 4 + te.x_advance + 3

    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 10)
    cairo_set_source_rgba(cr, lbl.c[1], lbl.c[2], lbl.c[3], 1.0)
    cairo_move_to(cr, name_x, LABEL_Y)
    cairo_show_text(cr, lbl.name)

    -- graph section — translate so modules draw relative to GRAPH_Y
    -- suppress module-internal draw_dividers (full widget borders already drawn above)
    local real_dd = draw_dividers
    draw_dividers = function() end

    cairo_save(cr)
    cairo_translate(cr, 0, GRAPH_Y)
    local gh = h - GRAPH_Y

    local view = VIEW_ORDER[view_idx]
    if view == "net" then
        NET_TOP_OFFSET = 31
        NET_BOT_OFFSET = 4
        draw_net_header(cr, w)
        net.draw(cr, w, gh)
    elseif view == "sys" then
        SYS_TOP_OFFSET = 31
        SYS_BOT_OFFSET = 4
        DISPLAY_GRAPH  = true
        sys.draw(cr, w, gh)
    else
        DISK_TOP_OFFSET = 31
        DISK_BOT_OFFSET = 4
        DISPLAY_GRAPH   = true
        disk.draw(cr, w, gh)
    end

    cairo_restore(cr)
    draw_dividers = real_dd

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end

-- ── Embedded conky config ─────────────────────────────────────────────────────

if conky then
    local _E = os.getenv("ENIGMA_DIR") or ((os.getenv("HOME") or "") .. "/.conky/enigma")

    conky.config = {
        update_interval    = 1,
        double_buffer      = true,
        diskio_avg_samples = 3,

        own_window             = true,
        own_window_type        = 'normal',
        own_window_title       = 'enigma-nsd2',
        own_window_transparent = true,
        own_window_argb_visual = true,
        own_window_argb_value  = 0,
        own_window_hints       = 'undecorated,below,sticky,skip_taskbar,skip_pager',

        alignment = 'top_right',
        gap_x     = 175,
        gap_y     = 200,

        minimum_width  = 150,
        maximum_width  = 150,
        minimum_height = 280,
        border_inner_margin = 2,
        border_outer_margin = 0,
        border_width        = 0,

        use_xft       = true,
        short_units   = true,
        font          = 'Roboto:size=7',
        default_color = 'ffffff',
        color2        = '2D9EEA',

        lua_load          = _E .. '/settings.lua ' .. _E .. '/widgets/nsd2.lua',
        lua_draw_hook_pre = 'main2',
        lua_mouse_hook    = 'mouse_hook2',
    }

    conky.text = [[${lua_parse nsd2_text}]]
end
