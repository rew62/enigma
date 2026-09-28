-- xena-net.lua — network section lifted from the Xena bar  (conky -c xena-net.lua)
--   ▲ upspeed / ▼ downspeed arrows + totals, Xena's #dddddd text styling
--   Background comes from the shared theme (settings.lua + scripts/draw_bg.lua)
--   Shift+left-click → toggle the interface down/up
--   While down: 2 px red border (and a red DOWN tag), otherwise none
--
-- NM-managed interfaces (wifi or wired) toggle via `nmcli device
-- disconnect/connect` — polkit allows that for a local session, no password.
-- Unmanaged interfaces fall back to `sudo -n ip link set`, which needs a
-- sudoers rule, e.g. in /etc/sudoers.d/conky-net:
--   bwebb ALL=(root) NOPASSWD: /usr/sbin/ip link set * up, /usr/sbin/ip link set * down
--
-- Lua functions first; conky.config/text guarded by `if conky` so this file
-- is also safe to load via lua_load without re-executing the config block.
-- v1 2026-07-09 @rew62

-- During config parse the `conky` global exists; cairo bindings aren't
-- registered yet so we skip the require.  lua_load re-runs this file
-- with conky=nil, at which point cairo is available.
if not conky then require 'cairo'; pcall(require, 'cairo_xlib') end  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local HOME       = os.getenv("HOME") or ""
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (HOME .. "/.conky/enigma")
package.path     = ENIGMA_DIR .. "/scripts/?.lua;" .. package.path

-- shared theme background: draw_bg() reads bg_color/bg_alpha globals set by settings.lua
local surface
if not conky then
    local ok, err = pcall(require, "draw_bg")
    if not ok then print("[xena-net] cannot load draw_bg: " .. tostring(err)); os.exit(1) end
    surface = require("surface")
end

-- ── User config ───────────────────────────────────────────────────────────────
local INTERFACE  = "auto"              -- "auto" = default-route iface, or e.g. "enp3s0"
local FONT       = "Neuropolitical"    -- Xena's font; cairo falls back if missing
local FONT_SIZE  = 12

local TEXT_RGBA  = { 0.867, 0.867, 0.867, 1 }  -- Xena #dddddd
local DIM_RGBA   = { 0.867, 0.867, 0.867, 0.55 }
local RED_RGBA   = { 0.85, 0.15, 0.15, 1 }     -- down-state border / tag

-- arrow/label colors matched to enigma/widgets/vnstat-summary.lua
local UP_RGBA    = { 0.941, 0.333, 0.333, 1 }  -- tx red    0xf05555
local DOWN_RGBA  = { 0.376, 0.784, 0.533, 1 }  -- rx green  0x60c888
local LABEL_RGBA = { 0.176, 0.620, 0.918, 1 }  -- head blue 0x2D9EEA

local W, H       = 150, 66

-- ── Interface detection / admin state ─────────────────────────────────────────
local function detect_iface()
    local p = io.popen("ip -o route show default 2>/dev/null")
    if p then
        local line = p:read("*l") or ""
        p:close()
        local dev = line:match(" dev (%S+)")
        if dev then return dev end
    end
    -- no default route (maybe we downed it last session): first non-lo iface
    local ls = io.popen("ls /sys/class/net 2>/dev/null")
    if ls then
        for name in ls:lines() do
            if name ~= "lo" then ls:close(); return name end
        end
        ls:close()
    end
    return "eth0"
end

local IFACE = (INTERFACE == "auto") and detect_iface() or INTERFACE

-- Detected once at load: is this device NetworkManager-managed?
local NM_MANAGED = (function()
    local p = io.popen("nmcli -t -f DEVICE,STATE device status 2>/dev/null")
    if not p then return false end
    for line in p:lines() do
        local dev, state = line:match("^([^:]+):(.*)$")
        if dev == IFACE then p:close(); return state ~= "unmanaged" end
    end
    p:close()
    return false
end)()

-- Up/down state.  NM path: `nmcli device disconnect` leaves the kernel link
-- IFF_UP (NM keeps watching carrier), so read NM's device state instead —
-- numeric prefix: 10 unmanaged / 20 unavailable / 30 disconnected /
-- 40-90 connecting / 100 connected / 110 deactivating / 120 failed.
-- Unmanaged path: IFF_UP flag, exactly what `ip link set up/down` toggles.
-- (operstate would also read "down" on carrier loss, which we don't want.)
local function iface_is_up()
    if NM_MANAGED then
        local p = io.popen("nmcli -g GENERAL.STATE device show " .. IFACE .. " 2>/dev/null")
        if p then
            local n = tonumber((p:read("*l") or ""):match("^(%d+)"))
            p:close()
            if n then return n >= 40 and n <= 100 end
        end
    end
    local f = io.open("/sys/class/net/" .. IFACE .. "/flags", "r")
    if not f then return false end
    local flags = tonumber(f:read("*l"))   -- e.g. "0x1003"
    f:close()
    return flags ~= nil and flags % 2 == 1
end

local function toggle_iface()
    local up = iface_is_up()
    local cmd
    if NM_MANAGED then
        -- per-device, works for wifi and wired alike, no root needed
        cmd = string.format("nmcli device %s %s",
                            up and "disconnect" or "connect", IFACE)
    else
        -- sudo -n: fail instead of hanging on a password prompt inside conky
        cmd = string.format("sudo -n ip link set %s %s",
                            IFACE, up and "down" or "up")
    end
    os.execute(cmd .. " >/dev/null 2>&1 &")
end

-- ─────────────────────────────────────────────────────────────────────────────

-- Short standardized units: floor at K so bytes never read as a big number
-- ("938B" glances bigger than "3MiB").  Fixed 2 decimals so the decimal
-- point never jumps: 0.92K · 42.00K · 3.10M · 1.20G.
-- Returns number and unit separately so the draw code can column-align them.
local function fmt_kib(kib)
    local units = { "K", "M", "G", "T" }
    local v, i = kib, 1
    while v >= 1000 and i < #units do v = v / 1024; i = i + 1 end
    return string.format("%.2f", v), units[i]
end

-- total tx/rx bytes from sysfs, so totals use the same short units
local function read_stat(name)
    local f = io.open("/sys/class/net/" .. IFACE .. "/statistics/" .. name, "r")
    if not f then return 0 end
    local v = tonumber(f:read("*l")) or 0
    f:close()
    return v
end

local function set_rgba(cr, c)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], c[4] or 1)
end

-- filled triangle: up=true points up, apex on the text baseline's midline
local function arrow(cr, x, y, size, up)
    local h = size
    if up then
        cairo_move_to(cr, x, y)
        cairo_line_to(cr, x + size, y)
        cairo_line_to(cr, x + size/2, y - h)
    else
        cairo_move_to(cr, x, y - h)
        cairo_line_to(cr, x + size, y - h)
        cairo_line_to(cr, x + size/2, y)
    end
    cairo_close_path(cr)
    cairo_fill(cr)
end

local function show_text(cr, text, x, y)
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, text)
end

local function right_text(cr, text, xr, y)
    local ext = cairo_text_extents_t:create(); tolua.takeownership(ext)
    cairo_text_extents(cr, text, ext)
    cairo_move_to(cr, xr - ext.width - ext.x_bearing, y)
    cairo_show_text(cr, text)
end

local function draw_net(cr, w, h)
    local up = iface_is_up()

    -- ── 2 px red border only while the link is admin-down ────────────────────
    if not up then
        set_rgba(cr, RED_RGBA)
        cairo_set_line_width(cr, 2)
        cairo_rectangle(cr, 1, 1, w-2, h-2)
        cairo_stroke(cr)
    end

    cairo_select_font_face(cr, FONT,
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, FONT_SIZE)

    -- ── Traffic vars: raw KiB/s floats + sysfs byte totals, our own units ────
    local parsed = conky_parse(string.format(
        "${upspeedf %s}|${downspeedf %s}", IFACE, IFACE))
    local upf, downf = parsed:match("([^|]*)|([^|]*)")
    local upn, upu = fmt_kib(tonumber(upf) or 0)
    local dnn, dnu = fmt_kib(tonumber(downf) or 0)
    local tun, tuu = fmt_kib(read_stat("tx_bytes") / 1024)
    local tdn, tdu = fmt_kib(read_stat("rx_bytes") / 1024)

    -- ── Row 1: interface name (+ DOWN tag) ────────────────────────────────────
    cairo_set_source_rgba(cr, LABEL_RGBA[1], LABEL_RGBA[2], LABEL_RGBA[3],
                          up and 1 or 0.55)
    show_text(cr, IFACE, 12, 18)
    if not up then
        set_rgba(cr, RED_RGBA)
        right_text(cr, "DOWN", w - 12, 18)
    end

    -- ── Rows 2/3: ▲ upspeed · total, ▼ downspeed · total ─────────────────────
    set_rgba(cr, UP_RGBA)
    -- up-pointing triangles read optically smaller; oversize it 1 px
    arrow(cr, 12.5, 38, 10, true)
    set_rgba(cr, DOWN_RGBA)
    arrow(cr, 13, 57, 9, false)

    -- number right-aligned to a fixed column, unit left-aligned after it:
    -- the decimal point and unit stay put, digits grow leftward
    local NUM_X = 66
    set_rgba(cr, up and TEXT_RGBA or DIM_RGBA)
    right_text(cr, upn, NUM_X, 39)
    show_text(cr, upu .. "/s", NUM_X + 2, 39)
    right_text(cr, dnn, NUM_X, 58)
    show_text(cr, dnu .. "/s", NUM_X + 2, 58)

    set_rgba(cr, DIM_RGBA)
    right_text(cr, tun .. tuu, w - 12, 39)
    right_text(cr, tdn .. tdu, w - 12, 58)
end

-- ─────────────────────────────────────────────────────────────────────────────

local _size_logged = false

function conky_draw_xena_net()
    if conky_window == nil then return end

    draw_bg()

    if not _size_logged and conky_window.width > 0 then
        print(string.format("[%s] window: %d x %d  iface: %s (%s)",
            conky_config:match("([^/]+)$"),
            conky_window.width, conky_window.height, IFACE,
            NM_MANAGED and "nmcli toggle" or "sudo ip link toggle"))
        _size_logged = true
    end

    local cs, owns = surface.get()
    if cs == nil then return end
    local cr = cairo_create(cs)
    draw_net(cr, conky_window.width, conky_window.height)
    cairo_destroy(cr)
    surface.put(cs, owns)
end

-- ─────────────────────────────────────────────────────────────────────────────

function conky_mouse_hook(event)
    if event.type == "button_down" and event.button == "left"
       and event.mods and event.mods.shift then
        toggle_iface()
        return true
    end
    return false
end

-- When loaded via lua_load, conky global is nil — skip config/text.
if conky then
    conky.config = {
        -- settings.lua first: publishes bg_color/bg_alpha before draw_bg() reads them
        lua_load          = ENIGMA_DIR .. '/settings.lua ' .. ENIGMA_DIR .. '/widgets/xena-net.lua',
        lua_draw_hook_pre = 'draw_xena_net',
        lua_mouse_hook    = 'mouse_hook',

        background             = false,
        own_window             = true,
        own_window_type        = 'normal',
        own_window_title       = 'xena-net',
        own_window_hints       = 'undecorated,below,sticky,skip_taskbar,skip_pager',
        own_window_argb_visual = true,
        own_window_argb_value  = 0,
        own_window_transparent = true,

        double_buffer          = true,
        minimum_width          = W,
        minimum_height         = H,
        maximum_width          = W,

        update_interval        = 1,
        net_avg_samples        = 2,
        no_buffers             = true,

        alignment              = 'top_left',
        gap_x                  = 100,
        gap_y                  = 100,
    }

    conky.text = [[]]
end
