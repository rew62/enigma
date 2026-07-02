-- nsd.lua – combined Net / Sys / Disk widget (enigma)
-- Shift+left-click cycles views: net → sys → disk → net
-- Shift+right-click toggles combo summary (all three headers + mid-values, no graphs)
-- Ctrl+left-click saves window position; Ctrl+right-click kills instance.
-- Net view: wifi/wired header + IP + speed graph + IN/OUT counts.
-- Sys view: CPU/RAM/UP/TEMP header + dual CPU tick graph.
-- Disk view: Disk/Used/Free header only (no graph).
-- v1 2026-07-04 @rew62

if not conky then require 'cairo' end

local _dir       = debug.getinfo(1, 'S').source:match("@?(.*/)") or "./"
local HOME       = os.getenv("HOME") or ""
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (HOME .. "/.conky/enigma")

package.path = _dir .. "?.lua;"
    .. ENIGMA_DIR .. "/scripts/?.lua;"
    .. ENIGMA_DIR .. "/widgets/?.lua;"
    .. package.path

local env = require("env")

-- ── State ─────────────────────────────────────────────────────────────────────

local VIEW_ORDER = { "net", "sys", "disk" }
local view_idx   = 1          -- cycles on shift+left-click
local DISK_DEV   = env.get("DISK_DEV", "nvme0n1")
local NET_IFACE  = env.get("INTERFACE_NAME", "wlp2s0")
local combo_mode = false

-- ── Module loading (skipped during config-parse pass when conky exists) ───────

local window, net, sys, disk

if not conky then
    local function try_req(mod)
        local ok, r = pcall(require, mod)
        if not ok then print("[nsd] cannot load " .. mod .. ": " .. r); os.exit(1) end
        return r
    end
    try_req("draw_bg")      -- globals: draw_bg(), draw_dividers(), try_require()
    window = try_req("window")
    net    = try_req("net")
    sys    = try_req("sys")
    disk   = try_req("disk")
    divider = "top,bottom"
end

-- ── Network conky.text ────────────────────────────────────────────────────────

-- U+E986 Material wifi  ·  U+F089D Symbols Nerd Font Mono wired LAN
local G_WIFI  = "\xEE\xA6\x86"
local G_WIRED = "\xF3\xB0\xB2\x9D"

-- IFACE/WIFI/WIRED are substituted in net_conky_text(); keep on one line so
-- conky renders the header as a single row with alignr placing the glyph right.
local _NET_TMPL = table.concat({
    "${if_match \"${wireless_essid IFACE}\" != \"\"}",
    "${if_match \"${wireless_essid IFACE}\" != \"off/any\"}",
    "${color2}${font Material:size=10}WIFI${alignr}${voffset -2}",
    "${font Rubik:bold:size=7}${color}${wireless_essid IFACE} ",
    "${color2}(${wireless_link_qual_perc IFACE}%)",
    "${else}",
    "${color2}${font Symbols Nerd Font Mono:size=10}WIRED${alignr}${voffset -2}",
    "${font Rubik:bold:size=7}${color}${gw_iface}",
    "${endif}",
    "${else}",
    "${color2}${font Symbols Nerd Font Mono:size=10}WIRED${alignr}${voffset -2}",
    "${font Rubik:bold:size=7}${color}${gw_iface}",
    "${endif}\n",
    "${font Rubik:bold:size=7}${color #9ed1ff}${addr ${gw_iface}}",
    "${alignr}${color}${texeci 86400 curl -s https://api.ipify.org}\n",
    "${voffset 115}${font Rubik:bold:size=7}${color2}IN: ${color}${tcp_portmon 1 32767 count}",
    "  ${offset 7}${color2}OUT: ${color}${tcp_portmon 32768 61000 count}",
    "${alignr}${color2}TOTAL: ${color}${tcp_portmon 1 65535 count}",
})

local function net_conky_text(iface)
    return _NET_TMPL
        :gsub("IFACE", iface)
        :gsub("WIFI",  G_WIFI)
        :gsub("WIRED", G_WIRED)
end

-- ── Combo summary view ────────────────────────────────────────────────────────
-- Three stacked sections (NET / SYS / DISK), each ~44 px.  No graphs.
-- All values read via conky_parse; module histories kept warm by conky_main.

local CO_HEAD  = { 0x2D/255, 0x9E/255, 0xEA/255 }
local CO_WHITE = { 0xe8/255, 0xe8/255, 0xe8/255 }
local CO_LINE  = { 0.38, 0.56, 0.88 }
local CO_TEMP_LO, CO_TEMP_HI = 30, 95

local function co_net_fmt(v)
    local kbs = tonumber(v) or 0
    if     kbs >= 1024 then return string.format("%.1fM", kbs / 1024)
    elseif kbs >= 1    then return string.format("%.1fk", kbs)
    else                    return "0b" end
end

local function draw_combo(cr, w, h)
    local M  = 4
    local LV = 72    -- left-value right edge
    local RL = 90    -- right-label left edge
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

    -- 13 px between every row; section gap = 7 px below mid to sep + 1 px sep + 12 px to next row1
    local TOPS = { 3, 62, 108 }

    -- ── NET ─────────────────────────────────────────────────────────────
    -- row 1 (+12): glyph | ssid/iface name
    -- row 2 (+25): local IP | public IP  (small – matches net graph view)
    -- row 3 (+38): Qual/GW + value | TCP + in/out
    -- mid  (+51): UP / DN speeds
    local y0      = TOPS[1]
    local essid   = conky_parse("${wireless_essid " .. NET_IFACE .. "}")
    local is_wifi = essid and essid ~= "" and essid ~= "off/any"
    local gw      = conky_parse("${gw_iface}") or NET_IFACE
    local iface   = is_wifi and NET_IFACE or gw

    cairo_set_font_size(cr, 12)
    if is_wifi then
        cairo_select_font_face(cr, "Material", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    else
        cairo_select_font_face(cr, "Symbols Nerd Font Mono", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    end
    sc(CO_HEAD)
    dl(M, y0 + 12, is_wifi and G_WIFI or G_WIRED)

    cairo_set_font_size(cr, 11)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(xr, y0 + 12, is_wifi and (essid or "--") or gw)

    cairo_set_font_size(cr, 9)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_WHITE)
    dl(M,  y0 + 25, gs("${addr " .. iface .. "}"))
    dr(xr, y0 + 25, gs("${texeci 86400 curl -s https://api.ipify.org}"))

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 38, is_wifi and "Qual" or "GW")
    dl(RL, y0 + 38, "TCP")
    cairo_set_font_size(cr, 11)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 38, is_wifi
        and (gs("${wireless_link_qual_perc " .. NET_IFACE .. "}") .. "%")
        or  "wired")
    dr(xr, y0 + 38, gs("${tcp_portmon 1 32767 count}") .. "/"
                 .. gs("${tcp_portmon 32768 61000 count}"))

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 51, "Up")
    dl(RL, y0 + 51, "Dn")
    cairo_set_font_size(cr, 11)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 51, co_net_fmt(gs("${upspeedf "   .. iface .. "}")))
    dr(xr, y0 + 51, co_net_fmt(gs("${downspeedf " .. iface .. "}")))

    sep(TOPS[2] - 1)

    -- ── SYS ─────────────────────────────────────────────────────────────
    y0 = TOPS[2]

    local bat_f = io.open("/sys/class/power_supply/BAT0/uevent", "r")
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
    cairo_set_font_size(cr, 11)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 12, gs("${cpu cpu0}") .. "%")
    dr(xr, y0 + 12, gs("${memperc}") .. "%")

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 25, "Up")
    dl(RL, y0 + 25, r2_lbl)
    cairo_set_font_size(cr, 11)
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
    cairo_set_font_size(cr, 11)
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
    cairo_set_font_size(cr, 11)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 12, gs("${fs_used_perc /}") .. "%")
    dr(xr, y0 + 12, gs("${fs_used /}"))

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 25, "Total")
    dl(RL, y0 + 25, "Free")
    cairo_set_font_size(cr, 11)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 25, gs("${fs_size /}"))
    dr(xr, y0 + 25, gs("${fs_free /}"))

    cairo_set_font_size(cr, 10)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(CO_HEAD)
    dl(M,  y0 + 38, "RD")
    dl(RL, y0 + 38, "WR")
    cairo_set_font_size(cr, 11)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(CO_WHITE)
    dr(LV, y0 + 38, gs("${diskio_read "  .. DISK_DEV .. "}"))
    dr(xr, y0 + 38, gs("${diskio_write " .. DISK_DEV .. "}"))

    draw_dividers(cr, w, h)
end

-- ── Conky hook functions ───────────────────────────────────────────────────────

function conky_nsd_text()
    if combo_mode then return "" end
    if VIEW_ORDER[view_idx] == "net" then
        return net_conky_text(NET_IFACE)
    end
    return "${voffset 116}"
end

function conky_mouse_hook(event)
    if window and window.handle_mouse(event) then return true end

    if event.type == "button_down" and event.mods then
        if event.button == "right" and event.mods.shift then
            combo_mode = not combo_mode
            print("[nsd] combo -> " .. tostring(combo_mode))
            return true
        end
        if event.button == "left" and event.mods.shift and not combo_mode then
            view_idx = (view_idx % #VIEW_ORDER) + 1
            print("[nsd] view -> " .. VIEW_ORDER[view_idx])
            return true
        end
    end
    return false
end

function conky_main()
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

    -- keep all graph histories warm regardless of active view/mode
    net.update(iface)
    sys.update()
    disk.update(DISK_DEV)

    if combo_mode then
        draw_combo(cr, w, h)
    else
        local view = VIEW_ORDER[view_idx]

        if view == "net" then
            NET_TOP_OFFSET = 32
            NET_BOT_OFFSET = 20
            net.draw(cr, w, h)

        elseif view == "sys" then
            SYS_TOP_OFFSET = 31
            SYS_BOT_OFFSET = 4
            DISPLAY_GRAPH  = true
            sys.draw(cr, w, h)

        else  -- disk
            DISK_TOP_OFFSET = 31
            DISK_BOT_OFFSET = 4
            DISPLAY_GRAPH   = true
            disk.draw(cr, w, h)
        end
    end

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end

-- ── Embedded conky config (only evaluated during the -c parse pass) ───────────

if conky then
    local _E = os.getenv("ENIGMA_DIR") or ((os.getenv("HOME") or "") .. "/.conky/enigma")

    conky.config = {
        update_interval    = 1,
        double_buffer      = true,
        diskio_avg_samples = 3,

        own_window             = true,
        own_window_type        = 'normal',
        own_window_title       = 'enigma-nsd',
        own_window_transparent = true,
        own_window_argb_visual = true,
        own_window_argb_value  = 0,
        own_window_hints       = 'undecorated,below,sticky,skip_taskbar,skip_pager',

        alignment = 'top_right',
        gap_x     = 175,
        gap_y     = 200,

        minimum_width  = 150,
        maximum_width  = 150,
        minimum_height = 154,
        border_inner_margin = 2,
        border_outer_margin = 0,
        border_width        = 0,

        use_xft       = true,
        short_units   = true,
        font          = 'Roboto:size=7',
        default_color = 'ffffff',
        color2        = '2D9EEA',

        lua_load          = _E .. '/settings.lua ' .. _E .. '/widgets/nsd.lua',
        lua_draw_hook_pre = 'main',
        lua_mouse_hook    = 'mouse_hook',
    }

    conky.text = [[${lua_parse nsd_text}]]
end
