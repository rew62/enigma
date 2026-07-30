-- settings.lua - Shared theme settings for the enigma conky suite
-- Replaces root theme.lua plus each widget's local settings.lua (one settings file
-- for the whole suite instead of 15 near-identical copies).
-- v1 2026-07-04 @rew62

local theme = {
    bg_color     = 0x1e1e2e,
    fg_color     = 0xcdd6f4,
    bg_alpha     = nil,      -- nil = derive from luma; set explicitly to override
    border_color = 0x000000, -- unused; border_alpha=0 hides it
    border_width = 0,
    border_alpha = 0.0,
    font         = "Sans 10",
    cairo_font   = "DejaVuSansM Nerd Font Propo",
    divider        = "",     -- edge rule: "top", "bottom", "top,bottom", or ""
    divider_margin = 3,      -- px gap between divider line and widget content
    divider_width  = 1,      -- px line width
    divider_color  = 0xf2f2f2, -- RGB hex
    divider_alpha  = 0.35,   -- opacity
}

local function read_luma()
    local fh = io.open("/dev/shm/conky/enigma_luma", "r")
    if not fh then return nil end
    local v = tonumber(fh:read("*l"))
    fh:close()
    return v
end

if theme.bg_alpha == nil then
    local luma = read_luma()
    theme.bg_alpha = luma and (luma * 4.0) or 0.0
end

for k, v in pairs(theme) do
    if _G[k] == nil then _G[k] = v end
end

conky_script_name = conky_config:match("([^/]+)$") or conky_config

-- Per-widget tunables, keyed by script basename (the same key
-- scripts/loadall.lua's WIDGETS table uses). Edit here to change a widget's
-- divider rule, turn its Ctrl+click move/kill off, or set a fixed pixel
-- size -- no Lua logic lives in this table, just values. The wiring that
-- consumes these (which setup function runs, which draw function gets
-- called) lives in scripts/loadall.lua instead. This file must load before
-- scripts/loadall.lua in every widget's lua_load (it already does) so these
-- values exist by the time loadall.lua's dispatch loop reads them.
WIDGET_CONFIG = {
    ["multimon.rc"]           = { divider = "top,bottom", globals = { WINDOW_MOUSE_HOOK = false } },
    ["disk.rc"]               = { divider = "top,bottom" },
    ["network.rc"]            = { divider = "top,bottom", globals = { WINDOW_MOUSE_HOOK = false } },
    ["system.rc"]             = { divider = "top,bottom", globals = { WINDOW_MOUSE_HOOK = false } },
    ["indices2.rc"]           = { divider = "top,bottom", globals = { INDICES2_EXPANDED = false } },
    ["horoscope.rc"]          = { divider = "top,bottom" },
    ["song-info.rc"]          = { globals = { WINDOW_MOUSE_HOOK = false } }, -- content-only; no window to drag
    ["playerctl.rc"]          = { globals = { WINDOW_MOUSE_HOOK = false } },
    ["ticker.rc"]             = { divider = "top,bottom" },
    ["vnstat-summary.rc"]     = { divider = "top,bottom", globals = { WINDOW_MOUSE_HOOK = false } },
    ["nws_forecast_small.rc"] = { target_width = 154, target_height = 94 },
    ["tempbar.rc"]            = { target_width = 154, target_height = 55, divider = "top,bottom" },
    ["worldmap.rc"]           = { divider = "bottom", globals = { WINDOW_MOUSE_HOOK = false } },
    ["espcal.lua"]            = { globals = { WINDOW_MOUSE_HOOK = false } },
    ["nsd.lua"]               = { divider = "top,bottom" },
    ["nsd2.lua"]              = { divider = "top,bottom" },
}

function conky_vars()
    conky_script_name = conky_config:match("([^/]+)$")
end
