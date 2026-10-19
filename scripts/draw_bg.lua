-- draw_bg.lua - Shared Cairo background + divider utilities for enigma widgets
-- Reads bg_color, bg_alpha, divider, divider_color, divider_alpha, divider_width
-- from globals set by theme/settings; bg_alpha = nil solves it from the
-- wallpaper (see "automatic pane opacity" below).
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

-- ── automatic pane opacity ───────────────────────────────────────────────────
-- bg_alpha = nil (settings.lua default): the pane's alpha is solved so that
-- fg_color holds bg_contrast against the wallpaper behind this window.
-- scripts/enigma_bg.py (one resident copy for the suite, started here when
-- not running) samples the brightest-ish wallpaper pixel behind every
-- registered widget into BG_DIR/samples.lua and bumps BG_DIR/serial; each
-- widget re-reads only when serial moves, solves every widget's alpha, and
-- pulls its own bg_alpha_pull of the way towards the most opaque so
-- neighbouring panes read as one material.

local BG_DIR     = "/dev/shm/enigma/bg"
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma"
local HELPER     = ENIGMA_DIR .. "/scripts/enigma_bg.py"
local HELPER_CHECK_EVERY = 30

local _auto = { alpha = 0, serial = nil, tick = nil, helper_at = nil, registered = false, synced = false }

local function rgb01(c)
    return ((c // 0x10000) % 0x100) / 255, ((c // 0x100) % 0x100) / 255, (c % 0x100) / 255
end

local function luminance(r, g, b)
    local function lin(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end

local function contrast(la, lb)
    if la < lb then la, lb = lb, la end
    return (la + 0.05) / (lb + 0.05)
end

-- Smallest pane alpha giving fg_color bg_contrast over wallpaper colour wall;
-- cairo blends in sRGB, so mix there and measure in linear light.
local function solve_alpha(wall, pane, ink_l, target)
    local function at(a)
        return contrast(ink_l, luminance(
            a * pane[1] + (1 - a) * wall[1],
            a * pane[2] + (1 - a) * wall[2],
            a * pane[3] + (1 - a) * wall[3]))
    end
    if at(0) >= target then return 0 end
    if at(1) < target then return 1 end
    local lo, hi = 0, 1
    for _ = 1, 16 do
        local mid = (lo + hi) / 2
        if at(mid) >= target then hi = mid else lo = mid end
    end
    return hi
end

local function read_line(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local function helper_running()
    local pid = tonumber(read_line(BG_DIR .. "/pid") or "")
    if not pid then return false end
    local cmd = read_line("/proc/" .. pid .. "/cmdline")
    return cmd ~= nil and cmd:find("enigma_bg.py", 1, true) ~= nil
end

local function auto_alpha()
    local now = os.time()
    if now == _auto.tick then return _auto.alpha end
    _auto.tick = now
    local name = conky_script_name

    if not _auto.registered and name then
        os.execute("mkdir -p " .. BG_DIR .. "/members")
        local f = io.open(BG_DIR .. "/members/" .. name, "w")
        if f then f:close(); _auto.registered = true end
    end
    if _auto.helper_at == nil or now - _auto.helper_at >= HELPER_CHECK_EVERY then
        _auto.helper_at = now
        if not helper_running() then
            os.execute("python3 '" .. HELPER .. "' >> " .. BG_DIR .. "/log 2>&1 &")
        end
    end

    local function load_samples()
        local chunk = loadfile(BG_DIR .. "/samples.lua", "t", {})
        local ok, samples = pcall(chunk or error)
        if ok and type(samples) == "table" and samples[name] ~= nil then return samples end
    end

    -- First draw with no sample for this window yet: scan once and wait, so
    -- a widget with a long update_interval doesn't keep an alpha-0 pane
    -- until its next update.
    if not _auto.synced then
        _auto.synced = true
        if not load_samples() then
            os.execute("python3 '" .. HELPER .. "' --once >> " .. BG_DIR .. "/log 2>&1")
        end
    end

    local serial = read_line(BG_DIR .. "/serial")
    if serial == nil or serial == _auto.serial then return _auto.alpha end
    local samples = load_samples()
    if not samples then return _auto.alpha end
    _auto.serial = serial

    local pane = { rgb01((type(bg_color) == "number") and bg_color or 0x1e1e2e) }
    local ink_l = luminance(rgb01((type(fg_color) == "number") and fg_color or 0xcdd6f4))
    local target = (type(bg_contrast) == "number") and bg_contrast or 7
    local mine, most = 0, 0
    for k, wall in pairs(samples) do
        local a = solve_alpha(wall, pane, ink_l, target)
        if k == name then mine = a end
        if a > most then most = a end
    end
    local pull = (type(bg_alpha_pull) == "number") and bg_alpha_pull or 0.35
    local a = mine + (most - mine) * pull
    local lo = (type(bg_alpha_min) == "number") and bg_alpha_min or 0
    local hi = (type(bg_alpha_max) == "number") and bg_alpha_max or 0.9
    _auto.alpha = math.max(lo, math.min(hi, a))
    print(string.format("[%s] auto bg_alpha %.2f (own %.2f, suite max %.2f)", name, _auto.alpha, mine, most))
    return _auto.alpha
end

function draw_bg(w, h)
    if conky_window == nil then return end
    local bg_a = (type(bg_alpha) == "number") and bg_alpha or auto_alpha()
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
