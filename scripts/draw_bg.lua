-- draw_bg.lua - Shared Cairo background + divider utilities for enigma widgets
-- Reads bg_color, bg_alpha, divider, divider_color, divider_alpha, divider_width
-- from globals set by theme/settings.
-- draw_bg()             → full window background
-- draw_bg(w, h)         → custom size background
-- draw_dividers(cr,w,h) → top/bottom hairlines per divider global
-- try_require(mod)      → pcall-wrapped require; prints error and exits on failure
-- log_window_size()     → one-time "[name] window: W x H" line once the window is up,
--                         plus publishes the window height to HEIGHTS_DIR whenever it
--                         changes, keyed by rc basename (etmux COLUMN stacking reads it)
-- v1 2026-07-04 @rew62
if not conky then require 'cairo'; pcall(require, 'cairo_xlib') end  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local surface = require("surface")

local HEIGHTS_DIR = "/dev/shm/enigma/heights"

local _size_logged = false
local _pub_height
function log_window_size()
    if conky_window == nil then return end
    if conky_window.width == 0 or conky_window.height == 0 then return end
    local name = conky_script_name
        or (conky_config and conky_config:match("([^/]+)$"))
        or "conky"
    if not _size_logged then
        print(string.format("[%s] window: %d x %d", name, conky_window.width, conky_window.height))
        _size_logged = true
    end
    if conky_window.height ~= _pub_height then
        os.execute("mkdir -p " .. HEIGHTS_DIR)
        local f = io.open(HEIGHTS_DIR .. "/" .. name, "w")
        if f then
            f:write(conky_window.height, "\n")
            f:close()
            _pub_height = conky_window.height
        end
    end
end

function try_require(mod)
    local ok, result = pcall(require, mod)
    if not ok then
        print("[enigma] failed to load " .. mod .. ": " .. tostring(result))
        os.exit(1)
    end
    return result
end

function draw_dividers(cr, w, h)
    local div = (type(divider) == "string") and divider or ""
    if div == "" then return end
    local _dc = (type(divider_color) == "number") and divider_color or 0xf2f2f2
    local _da = (type(divider_alpha) == "number") and divider_alpha or 0.35
    cairo_set_source_rgba(cr,
        ((_dc/0x10000)%0x100)/255,
        ((_dc/0x100)%0x100)/255,
        (_dc%0x100)/255, _da)
    cairo_set_line_width(cr, (type(divider_width) == "number") and divider_width or 1)
    if div:find("top") then
        cairo_move_to(cr, 0, 0.5);     cairo_line_to(cr, w, 0.5);     cairo_stroke(cr)
    end
    if div:find("bottom") then
        cairo_move_to(cr, 0, h - 0.5); cairo_line_to(cr, w, h - 0.5); cairo_stroke(cr)
    end
end

function draw_bg(w, h)
    if conky_window == nil then return end
    local bg_a = (type(bg_alpha) == "number") and bg_alpha or 0
    if bg_a <= 0 then return end
    local _bc = (type(bg_color) == "number") and bg_color or 0x1e1e2e
    local cw = conky_window
    local cs, owns = surface.get()
    if cs == nil then return end
    local cr = cairo_create(cs)
    cairo_set_operator(cr, CAIRO_OPERATOR_DEST_OVER)
    cairo_set_source_rgba(cr,
        ((_bc/0x10000)%0x100)/255,
        ((_bc/0x100)%0x100)/255,
        (_bc%0x100)/255,
        bg_a)
    cairo_rectangle(cr, 0, 0, w or cw.width, h or cw.height)
    cairo_fill(cr)
    cairo_destroy(cr)
    surface.put(cs, owns)
end
