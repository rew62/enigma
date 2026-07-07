-- enigma-clock.lua — minimal ring clock  (conky -c enigma-clock.lua)
--   Inner disc  → mostly opaque, digital time + date
--   Outer ring  → transparent circle, 150 px overall
--   Dot         → sweeps the ring once per minute, smooth sub-second motion
--
-- Lua functions first; conky.config/text guarded by `if conky` so this file
-- is also safe to load via lua_load without re-executing the config block.
-- v1 2026-07-07 @rew62

-- During config parse the `conky` global exists; cairo bindings aren't
-- registered yet so we skip the require.  lua_load re-runs this file
-- with conky=nil, at which point cairo is available.
if not conky then require 'cairo'; pcall(require, 'cairo_xlib') end  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local _clock_dir = debug.getinfo(1,'S').source:match("@?(.*/)" ) or "./"
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma"
package.path = _clock_dir .. "?.lua;" .. _clock_dir .. "../scripts/?.lua;" .. package.path
    .. ";" .. ENIGMA_DIR .. "/scripts/?.lua"

-- standalone load: bypasses settings.lua/loadall.lua/draw_bg.lua pipeline, so
-- the shared try_require isn't available globally here.
local function try_require(mod)
    local ok, result = pcall(require, mod)
    if not ok then
        print("[enigma] failed to load " .. mod .. ": " .. tostring(result))
        os.exit(1)
    end
    return result
end

local window = try_require("window")

-- ── User config ───────────────────────────────────────────────────────────────
local TIME_FMT   = "%I:%M"       -- big digits; zero-stripped, "a"/"p" appended below
local DATE_FMT   = "%a %d %b"    -- below the time
local LABEL      = "Current Time"
local FONT       = "DejaVu Sans" -- try "DejaVu Sans Light" for thinner digits

local FACE_RGBA  = { 0.16, 0.18, 0.21, 0.92 }  -- inner disc (mostly opaque)
local RING_RGBA  = { 1.00, 1.00, 1.00, 0.35 }  -- outer circle (transparent)
local DOT_RGB    = { 0.70, 0.53, 0.88 }        -- seconds dot (purple)
local TEXT_RGBA  = { 1.00, 1.00, 1.00, 0.95 }  -- time digits
local DIM_RGBA   = { 1.00, 1.00, 1.00, 0.60 }  -- label + date

-- Design coordinates for a 150 px canvas; everything scales from window size.
local DESIGN     = 150
local RING_R     = 66            -- ring radius (dot rides on it, 7 px radius)
local FACE_R     = 55            -- inner disc radius

-- ── Sub-second wall clock ─────────────────────────────────────────────────────
-- os.time() only ticks whole seconds, so the dot would jump 6° at a time.
-- Calibrate once at load: wall = WALL_OFFSET + /proc/uptime, then every frame
-- is a cheap sysfs read with nanosecond-ish resolution and no process spawn.
local function read_uptime()
    local f = io.open("/proc/uptime", "r")
    if not f then return nil end
    local v = f:read("*n")
    f:close()
    return v
end

local WALL_OFFSET = (function()
    local up = read_uptime()
    if up then
        local p = io.popen("date +%s.%N 2>/dev/null")
        if p then
            local wall = tonumber(p:read("*l"))
            p:close()
            if wall then return wall - up end
        end
    end
    return nil
end)()

-- Seconds within the current minute, fractional. Timezone offsets are whole
-- minutes, so epoch % 60 matches the local clock's seconds hand.
local function sec_in_minute()
    if WALL_OFFSET then
        local up = read_uptime()
        if up then return (WALL_OFFSET + up) % 60 end
    end
    return os.time() % 60
end

-- ─────────────────────────────────────────────────────────────────────────────

local function set_rgba(cr, c)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], c[4] or 1)
end

local function center_text(cr, text, cx, y, size)
    cairo_select_font_face(cr, FONT,
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local ext = cairo_text_extents_t:create()
    cairo_text_extents(cr, text, ext)
    cairo_move_to(cr, cx - ext.width/2 - ext.x_bearing, y)
    cairo_show_text(cr, text)
end

local function clock(cr, w, h)
    local s  = math.min(w, h) / DESIGN
    local cx = w / 2
    local cy = h / 2

    cairo_set_source_rgba(cr, 0, 0, 0, 0)
    cairo_paint(cr)

    -- ── Inner disc ────────────────────────────────────────────────────────────
    set_rgba(cr, FACE_RGBA)
    cairo_arc(cr, cx, cy, FACE_R * s, 0, 2*math.pi)
    cairo_fill(cr)

    -- ── Outer ring ────────────────────────────────────────────────────────────
    set_rgba(cr, RING_RGBA)
    cairo_set_line_width(cr, 3 * s)
    cairo_arc(cr, cx, cy, RING_R * s, 0, 2*math.pi)
    cairo_stroke(cr)

    -- ── Seconds dot (12 o'clock = :00, sweeps clockwise) ─────────────────────
    local ang = sec_in_minute() / 60 * 2*math.pi - math.pi/2
    local dx  = cx + RING_R * s * math.cos(ang)
    local dy  = cy + RING_R * s * math.sin(ang)
    cairo_set_source_rgb(cr, DOT_RGB[1], DOT_RGB[2], DOT_RGB[3])
    cairo_arc(cr, dx, dy, 7 * s, 0, 2*math.pi)
    cairo_fill(cr)

    -- ── Text ──────────────────────────────────────────────────────────────────
    set_rgba(cr, DIM_RGBA)
    center_text(cr, LABEL, cx, cy - 22 * s, 10 * s)

    set_rgba(cr, TEXT_RGBA)
    local ampm = os.date("%p"):sub(1, 1):lower()   -- "a" / "p"
    -- Lua 5.4 rejects glibc's %-I, so strip the leading zero here instead
    local time_txt = os.date(TIME_FMT):gsub("^0", "")
    -- digits big, a/p smaller on the same baseline; center the pair as one unit
    local big, small, gap = 30 * s, 14 * s, 4 * s
    local t_ext = cairo_text_extents_t:create()
    local a_ext = cairo_text_extents_t:create()
    cairo_select_font_face(cr, FONT,
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, big)
    cairo_text_extents(cr, time_txt, t_ext)
    cairo_set_font_size(cr, small)
    cairo_text_extents(cr, ampm, a_ext)
    local x = cx - (t_ext.width + gap + a_ext.width) / 2
    local y = cy + 12 * s
    cairo_set_font_size(cr, big)
    cairo_move_to(cr, x - t_ext.x_bearing, y)
    cairo_show_text(cr, time_txt)
    cairo_set_font_size(cr, small)
    cairo_move_to(cr, x + t_ext.width + gap - a_ext.x_bearing, y)
    cairo_show_text(cr, ampm)

    set_rgba(cr, DIM_RGBA)
    center_text(cr, os.date(DATE_FMT), cx, cy + 32 * s, 10 * s)
end

-- ─────────────────────────────────────────────────────────────────────────────

local _size_logged = false

function conky_draw_enigma_clock()
    if conky_window == nil then return end

    if not _size_logged and conky_window.width > 0 then
        print(string.format("[%s] window: %d x %d",
            conky_config:match("([^/]+)$"), conky_window.width, conky_window.height))
        _size_logged = true
    end

    local cs = cairo_xlib_surface_create(
        conky_window.display,
        conky_window.drawable,
        conky_window.visual,
        conky_window.width,
        conky_window.height
    )
    local cr = cairo_create(cs)
    clock(cr, conky_window.width, conky_window.height)
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end

-- ─────────────────────────────────────────────────────────────────────────────

function conky_mouse_hook(event)
    return window.handle_mouse(event)
end

-- When loaded via lua_load, conky global is nil — skip config/text.
if conky then
    conky.config = {
        lua_load          = './enigma-clock.lua',
        lua_draw_hook_pre = 'draw_enigma_clock',
        lua_mouse_hook    = 'mouse_hook',

        background             = false,
        own_window             = true,
        own_window_type        = 'normal',
        own_window_title       = 'enigma-clock',
        own_window_hints       = 'undecorated,below,sticky,skip_taskbar,skip_pager',
        own_window_argb_visual = true,
        own_window_argb_value  = 0,
        own_window_transparent = true,

        double_buffer          = true,
        minimum_width          = 150,
        minimum_height         = 150,
        maximum_width          = 150,

        draw_shades            = false,
        draw_borders           = false,
        draw_outline           = false,

        -- 0.1 s ≈ 0.6° of dot travel per frame; raise to lighten CPU use
        update_interval        = 0.1,

        -- Position moved via Alt+drag, saved via Ctrl+left-click
        alignment              = 'top_right',
        gap_x                  = 400,
        gap_y                  = 60,
    }

    conky.text = [[]]
end
