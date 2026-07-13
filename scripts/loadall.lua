-- loadall.lua - Shared external-module loader + conky_main/mouse_hook runner
-- for enigma widgets that live flat in widgets/ (no per-widget loadall.lua).
-- Looks up the .rc/.lua basename in WIDGETS below.
-- v1 2026-07-04 @rew62

local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma"
package.path = "./?.lua;../?.lua;./scripts/?.lua;../scripts/?.lua;" .. package.path
    .. ";" .. ENIGMA_DIR .. "/scripts/?.lua"

require("draw_bg")    -- defines global try_require(), draw_bg(), draw_dividers()
require("functions")  -- defines global conky_fmtpct(), conky_fmtspeed()
local env     = require("env")
local surface = require("surface")

-- ── per-widget setup functions ──────────────────────────────────────────────
-- For widgets too custom for the generic cfg.runner case below (their own
-- conky_vars, height-helper, or mouse-hook logic). Called after cfg.modules
-- have been try_require()'d, so a plain require() here just hits the cache.
--
-- disk.rc / network.rc need their OWN conky_vars (reads template1 into a
-- local dev/iface var) to win over settings.lua's generic one, so these
-- three widgets load settings.lua BEFORE this file -- which is now true for
-- every widget, since settings.lua's WIDGET_CONFIG (read below) has to
-- exist before the dispatch loop runs regardless.

local function setup_disk()
    local window = require("window")
    local disk   = require("disk")
    local dev    = env.get("DISK_DEV", "nvme0n1")

    DISK_TOP_OFFSET = 31
    DISK_BOT_OFFSET = 4
    DISPLAY_GRAPH   = true

    function conky_disk_height()
        if DISPLAY_GRAPH ~= false then
            return "${voffset 116}"  -- header (31) + graph (85) + pad (4) = 120px
        else
            return "${voffset 30}"   -- header (31) + RD/WR footer line (16) + pad (4)
        end
    end

    function conky_vars()
        conky_script_name = conky_config:match("([^/]+)$")
        local t = conky_parse("${template1}")
        if t and t ~= "" then dev = t end
        print("enigma-disk: dev=" .. dev)
    end

    function conky_mouse_hook(event)
        if window.handle_mouse(event) then return true end

        -- Shift+left-click: toggle the tick graph on/off (header-only mode)
        if event.type == "button_down" and event.button == "left" and event.mods and event.mods.shift then
            DISPLAY_GRAPH = (DISPLAY_GRAPH == false)
            print("enigma-disk: DISPLAY_GRAPH -> " .. tostring(DISPLAY_GRAPH))
            return true
        end

        return false
    end

    function conky_main()
        if conky_window == nil then return end
        if conky_window.width == 0 or conky_window.height == 0 then return end

        draw_bg()

        local cs, owns = surface.get()
        if cs == nil then return end
        local cr = cairo_create(cs)

        disk.update(dev)
        disk.draw(cr, conky_window.width, conky_window.height)

        cairo_destroy(cr)
        surface.put(cs, owns)

        log_window_size()
    end
end

local function setup_network()
    local window = require("window")
    local net    = require("net")
    local iface  = "wlp2s0"

    NET_TOP_OFFSET = 32
    NET_BOT_OFFSET = 20

    local G_WIFI  = "\xEE\xA6\x86"      -- Material wifi glyph
    local G_WIRED = "\xF3\xB0\xB2\x9D"  -- Nerd Font lan glyph

    -- populated once per tick by conky_main() below -- the sole ad-hoc
    -- conky_parse() caller for wireless_essid/gw_iface, since on conky 1.22.x
    -- a redundant call to either within the same update tick reads back
    -- "(null)"/empty instead of the real value (see nsd.lua for the same fix)
    local net_essid, net_is_wifi, net_iface = "", false, iface

    -- header + addr lines for network.rc's ${lua_parse net_text}; embeds the
    -- already-resolved essid/iface as literals instead of re-referencing
    -- ${wireless_essid}/${gw_iface} live
    function conky_net_text()
        local header
        if net_is_wifi then
            header = "${color2}${font Material:size=10}" .. G_WIFI .. "${alignr}${voffset -2}"
                .. "${font Rubik:bold:size=7}${color}" .. net_essid .. " "
                .. "${color2}(${wireless_link_qual_perc " .. net_iface .. "}%)"
        else
            header = "${color2}${font Symbols Nerd Font Mono:size=10}" .. G_WIRED .. "${alignr}${voffset -2}"
                .. "${font Rubik:bold:size=7}${color}" .. net_iface
        end
        return header .. "\n"
            .. "${font Rubik:bold:size=7}${color #9ed1ff}${addr " .. net_iface .. "}"
            .. "${alignr}${color}${texeci 86400 curl -s https://api.ipify.org}"
    end

    function conky_vars()
        conky_script_name = conky_config:match("([^/]+)$")
        local t = conky_parse("${template1}")
        if t and t ~= "" then iface = t end
        net_iface = iface
        print("enigma-net: iface=" .. iface)
    end

    function conky_mouse_hook(event)
        return window.handle_mouse(event)
    end

    function conky_main()
        if conky_window == nil then return end
        if conky_window.width == 0 or conky_window.height == 0 then return end

        draw_bg()

        local cs, owns = surface.get()
        if cs == nil then return end
        local cr = cairo_create(cs)

        local active_iface = iface
        local essid = conky_parse("${wireless_essid " .. iface .. "}")
        local is_wifi = essid and essid ~= "" and essid ~= "off/any"
        if not is_wifi then
            local gw = conky_parse("${gw_iface}")
            if gw and gw ~= "" then active_iface = gw end
        end
        net_essid, net_is_wifi, net_iface = essid or "", is_wifi, active_iface
        net.update(active_iface)
        net.draw(cr, conky_window.width, conky_window.height)

        cairo_destroy(cr)
        surface.put(cs, owns)

        log_window_size()
    end
end

local function setup_system()
    local window = require("window")
    local sys    = require("sys")

    SYS_TOP_OFFSET = 31
    SYS_BOT_OFFSET = 4
    DISPLAY_GRAPH  = true

    function conky_sys_height()
        if DISPLAY_GRAPH ~= false then
            return "${voffset 116}"  -- header (31) + graph (85) + pad (4) = 120px
        else
            return "${voffset 12}"   -- header-only: tightened to ~4px below last glyph
        end
    end

    function conky_mouse_hook(event)
        return window.handle_mouse(event)
    end

    function conky_main()
        if conky_window == nil then return end
        if conky_window.width == 0 or conky_window.height == 0 then return end

        draw_bg()

        local cs, owns = surface.get()
        if cs == nil then return end
        local cr = cairo_create(cs)

        sys.update()
        sys.draw(cr, conky_window.width, conky_window.height)

        cairo_destroy(cr)
        surface.put(cs, owns)

        log_window_size()
    end
end

-- Shared by nws_forecast_small.rc and tempbar.rc: both force conky_window to
-- an exact target size every frame (border_inner_margin's auto-grow doesn't
-- reliably apply to these empty-conky.text widgets), and both use
-- lua_startup_hook = 'weather_update' instead of the usual 'vars'. cfg here
-- is the same per-widget table from WIDGETS below (cfg.update_fn/draw_fn/
-- target_width/target_height).
local function setup_weather(cfg)
    local window = require("window")

    function conky_mouse_hook(event)
        return window.handle_mouse(event)
    end

    function conky_weather_update()
        local update_func = _G[cfg.update_fn]
        if update_func then
            update_func()
        else
            print("WARNING: No update function mapped for " .. tostring(cfg.update_fn))
        end
    end

    function conky_main()
        if conky_window == nil then return end

        if conky_window.width ~= cfg.target_width or conky_window.height ~= cfg.target_height then
            conky_window.width  = cfg.target_width
            conky_window.height = cfg.target_height
        end

        -- update_fn's underlying fetchers are TTL-gated on disk (see
        -- nws_fetch.lua / owm_fetch.lua), so calling every frame is cheap
        -- and keeps current-conditions data from freezing at startup
        conky_weather_update()

        draw_bg()

        local draw_func = _G[cfg.draw_fn]
        if draw_func then draw_func() end

        local cs, owns = surface.get()
        if cs == nil then return end
        local cr = cairo_create(cs)
        draw_dividers(cr, conky_window.width, conky_window.height)
        cairo_destroy(cr)
        surface.put(cs, owns)

        log_window_size()
    end
end

local function setup_terminator()
    local window = require("window")

    function conky_mouse_hook(event)
        return window.handle_mouse(event)
    end

    function conky_main()
        if conky_window == nil then return end
        if conky_window.width == 0 or conky_window.height == 0 then return end

        draw_bg()
        conky_draw_worldmap()

        local cs, owns = surface.get()
        if cs == nil then return end
        local cr = cairo_create(cs)
        draw_dividers(cr, conky_window.width, conky_window.height)
        cairo_destroy(cr)
        surface.put(cs, owns)

        log_window_size()
    end
end

-- cfg.modules: list of scripts/ module names to try_require, in order
-- cfg.setup:   function called (after cfg.modules load) for widgets needing
--              full custom conky_main/conky_mouse_hook/conky_vars/etc.
-- cfg.runner:  true to also define conky_main/conky_mouse_hook (bg + dividers
--              + window click handling) for widgets with no Lua draw hook of
--              their own (e.g. multimon.rc, whose content comes from
--              conky.text). Widgets that draw themselves via lua_draw_hook_*
--              (arc.rc) omit this and define conky_mouse_hook themselves
--              instead.
-- cfg.draw_fn: global function name conky_main calls after the background,
--              for runner widgets that do need a Lua-drawn extra (nil = none)
-- cfg.draw_bg_args: function() -> bg_w, bg_h, called right before draw_bg()
--              for runner widgets whose background isn't the full window
--              (e.g. gcal.rc, where the bg height tracks the actual agenda
--              content height instead of the window's minimum_height)
-- cfg.mouse_hook: function(event, window) -> true/false/nil, tried before the
--              default window.handle_mouse() fallback; nil falls through to
--              it. For runner widgets with extra click behavior of their own
--              (e.g. indices2.rc's Shift+left-click expand/collapse toggle).
--
-- This table is wiring only (which function runs, not what value it uses).
-- Tunable per-widget VALUES -- divider rule, Shift/Ctrl-click move/kill
-- on/off, fixed target size -- live in settings.lua's WIDGET_CONFIG instead, since
-- that's the file meant for a human to edit without reading Lua logic.
-- Merged in below: WIDGET_CONFIG's divider sets the global `divider`
-- unconditionally (not a nil-check, so it wins regardless of whether
-- settings.lua's own theme-defaulting loop ran before or after), its
-- globals get force-set the same way, and target_width/target_height get
-- merged onto cfg for setup_weather to read. (Conky parses the -c file in a
-- throwaway Lua pass to extract conky.config/conky.text *before* lua_load
-- ever runs, so a bare global set there -- or in this file, if settings.lua
-- hadn't already loaded -- never reaches the real lua_load state. That's
-- why these values live in settings.lua, loaded first, rather than here.)
local BG_PADDING_GCAL = 16

local WIDGETS = {
    ["arc.rc"]      = { modules = { "window", "owm_fetch", "nws_fetch" } },
    ["enigma-earth.lua"] = { modules = { "window" } },
    ["multimon.rc"] = { modules = { "window" }, runner = true },
    ["disk.rc"]     = { modules = { "window", "disk" }, setup = setup_disk },
    ["network.rc"]  = { modules = { "window", "net" },  setup = setup_network },
    ["system.rc"]   = { modules = { "window", "sys" },  setup = setup_system },
    ["gcal.rc"]     = {
        modules = { "window", "gcal" }, runner = true, draw_fn = "conky_draw_gcal",
        draw_bg_args = function() return nil, gcal_prefetch() + BG_PADDING_GCAL end,
    },
    ["indices2.rc"] = {
        modules = { "window", "indices2" }, runner = true, draw_fn = "conky_draw_indices2",
        mouse_hook = function(event, window)
            if window.handle_mouse(event) then return true end
            if event.type == "button_down" and event.button == "left" then
                INDICES2_EXPANDED = not (INDICES2_EXPANDED == true)
                print("enigma-indices2: INDICES2_EXPANDED -> " .. tostring(INDICES2_EXPANDED))
                return true
            end
            return false
        end,
    },
    -- content comes entirely from conky.text (execi'd shell scripts); window
    -- move/kill is disabled via WIDGET_CONFIG in settings.lua
    ["song-info.rc"] = { modules = { "window" }, runner = true },
    ["playerctl.rc"] = { modules = { "window" }, runner = true },
    ["ticker.rc"]    = { modules = { "window", "ticker" }, runner = true, draw_fn = "conky_draw_stocks" },
    ["vnstat-summary.rc"] = {
        modules = { "window", "vnstat-summary" }, runner = true,
        draw_fn = "conky_draw_vnstat_summary",
    },
    ["nws_forecast_small.rc"] = {
        modules = { "window", "nws_fetch", "draw_nws_forecast_small" }, setup = setup_weather,
        update_fn = "weather_update", draw_fn = "conky_weather_main",
    },
    ["tempbar.rc"] = {
        modules = { "window", "nws_fetch", "owm_fetch", "draw_tempbar" }, setup = setup_weather,
        update_fn = "tempbar_update", draw_fn = "conky_weather_main",
    },
    ["worldmap.rc"] = { modules = { "window", "worldmap" }, setup = setup_terminator },
}

local script_name = conky_config:match("([^/]+)$") or conky_config
local cfg = WIDGETS[script_name]
if cfg then
    local wc = (WIDGET_CONFIG and WIDGET_CONFIG[script_name]) or {}
    if wc.divider then divider = wc.divider end
    for k, v in pairs(wc.globals or {}) do _G[k] = v end
    cfg.target_width  = wc.target_width  or cfg.target_width
    cfg.target_height = wc.target_height or cfg.target_height

    for _, mod in ipairs(cfg.modules or {}) do try_require(mod) end

    if cfg.setup then
        cfg.setup(cfg)
    elseif cfg.runner then
        local window = require("window")

        function conky_mouse_hook(event)
            if cfg.mouse_hook then
                local handled = cfg.mouse_hook(event, window)
                if handled ~= nil then return handled end
            end
            return window.handle_mouse(event)
        end

        function conky_main()
            if conky_window == nil then return end
            if conky_window.width == 0 or conky_window.height == 0 then return end

            local bg_w, bg_h
            if cfg.draw_bg_args then bg_w, bg_h = cfg.draw_bg_args() end
            draw_bg(bg_w, bg_h)

            local draw_fn = cfg.draw_fn and _G[cfg.draw_fn]
            if draw_fn then draw_fn() end

            local cs, owns = surface.get()
            if cs == nil then return end
            local cr = cairo_create(cs)
            draw_dividers(cr, conky_window.width, conky_window.height)
            cairo_destroy(cr)
            surface.put(cs, owns)

            log_window_size()
        end
    end
else
    print("loadall: no WIDGETS entry for " .. script_name)
end
