-- enigma-clock-v2.lua — minimal ring clock, three hands  (conky -c enigma-clock-v2.lua)
--   Inner disc  → mostly opaque, digital time only
--   Three rings → hour, minute, second (inside → out), 150 px overall
--   Dots        → one per ring, smooth sub-second motion
--
-- Lua functions first; conky.config/text guarded by `if conky` so this file
-- is also safe to load via lua_load without re-executing the config block.
-- v2 2026-07-08 @rew62

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
local TIME_FMT   = "%I:%M"       -- digits; zero-stripped, "a"/"p" appended below
local FONT       = "DejaVu Sans" -- try "DejaVu Sans Light" for thinner digits

local FACE_RGBA  = { 0.16, 0.18, 0.21, 0.00 }  -- inner disc (alpha 0 = no disc)
local TEXT_RGBA  = { 1.00, 1.00, 1.00, 0.95 }  -- time digits

-- One entry per ring, inside → out. Dial in per-ring:
--   r     = ring radius        width   = ring line width
--   dot   = dot radius         ring_rgba / dot_rgb = colors
local RINGS = {
    -- ring_rgba: 80% white + 20% of the ring's dot color, at v1's ring alpha
    { name = "hour",   r = 34, width = 2  , dot = 7,
      ring_rgba = { 0.96, 0.96, 0.95, 0.40 }, dot_rgb = { 0.70, 0.53, 0.88 } },  -- b387e0 (v1 dot purple)
    { name = "minute", r = 50, width = 1.5, dot = 7,
      ring_rgba = { 0.84, 0.92, 0.98, 0.40 }, dot_rgb = { 0.18, 0.62, 0.92 } },  -- 2d9eea
    { name = "second", r = 66, width = 3  , dot = 7,
      ring_rgba = { 0.99, 0.89, 0.84, 0.40 }, dot_rgb = { 0.95, 0.45, 0.20 } },  -- f27333
}

-- Design coordinates for a 150 px canvas; everything scales from window size.
local DESIGN     = 150
local FACE_R     = 28            -- inner disc radius

-- ── Sub-second wall clock ─────────────────────────────────────────────────────
-- os.time() only ticks whole seconds, so the dots would jump in steps.
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

-- Fraction of the way around each ring (0–1), all smooth
local function hand_fracs()
    local t   = os.date("*t")
    local sec = sec_in_minute()
    return {
        hour   = ((t.hour % 12) + t.min / 60 + sec / 3600) / 12,
        minute = (t.min + sec / 60) / 60,
        second = sec / 60,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────

local function set_rgba(cr, c)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], c[4] or 1)
end

local function clock(cr, w, h)
    local s  = math.min(w, h) / DESIGN
    local cx = w / 2
    local cy = h / 2

    cairo_set_source_rgba(cr, 0, 0, 0, 0)
    cairo_paint(cr)

    -- ── Inner disc ────────────────────────────────────────────────────────────
    if (FACE_RGBA[4] or 0) > 0 then
        set_rgba(cr, FACE_RGBA)
        cairo_arc(cr, cx, cy, FACE_R * s, 0, 2*math.pi)
        cairo_fill(cr)
    end

    -- ── Rings + dots (12 o'clock = zero, sweeps clockwise) ───────────────────
    local fracs = hand_fracs()
    for _, ring in ipairs(RINGS) do
        set_rgba(cr, ring.ring_rgba)
        cairo_set_line_width(cr, ring.width * s)
        cairo_arc(cr, cx, cy, ring.r * s, 0, 2*math.pi)
        cairo_stroke(cr)

        local ang = fracs[ring.name] * 2*math.pi - math.pi/2
        local dx  = cx + ring.r * s * math.cos(ang)
        local dy  = cy + ring.r * s * math.sin(ang)
        cairo_set_source_rgb(cr, ring.dot_rgb[1], ring.dot_rgb[2], ring.dot_rgb[3])
        cairo_arc(cr, dx, dy, ring.dot * s, 0, 2*math.pi)
        cairo_fill(cr)
    end

    -- ── Time ──────────────────────────────────────────────────────────────────
    set_rgba(cr, TEXT_RGBA)
    local ampm = os.date("%p")                     -- "AM" / "PM"
    -- Lua 5.4 rejects glibc's %-I, so strip the leading zero here instead
    local time_txt = os.date(TIME_FMT):gsub("^0", "")
    -- digits on top, AM/PM centered on the line below; block centered in circle
    local big, small = 14 * s, 8 * s
    local ext = cairo_text_extents_t:create()
    cairo_select_font_face(cr, FONT,
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    for _, row in ipairs({ { time_txt, big, cy },
                           { ampm, small, cy + 10 * s } }) do
        cairo_set_font_size(cr, row[2])
        cairo_text_extents(cr, row[1], ext)
        cairo_move_to(cr, cx - ext.width/2 - ext.x_bearing, row[3])
        cairo_show_text(cr, row[1])
    end
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

        -- 0.1 s ≈ 0.6° of second-dot travel per frame; raise to lighten CPU use
        update_interval        = 0.1,

        -- Position moved via Alt+drag, saved via Ctrl+left-click
        alignment              = 'top_right',
        gap_x                  = 400,
        gap_y                  = 50,
    }

    conky.text = [[]]
end
