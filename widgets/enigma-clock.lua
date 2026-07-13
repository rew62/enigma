-- enigma-clock.lua — minimal ring clock, three hands  (conky -c enigma-clock.lua)
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

local window  = try_require("window")
local surface = try_require("surface")

-- ── User config ───────────────────────────────────────────────────────────────
local TIME_FMT   = "%I:%M"       -- digits; zero-stripped, "a"/"p" appended below
local FONT       = "DejaVu Sans" -- try "DejaVu Sans Light" for thinner digits

local FACE_RGBA  = { 0.16, 0.18, 0.21, 0.00 }  -- inner disc (alpha 0 = no disc)
local TEXT_RGBA  = { 0.85, 0.85, 0.85, 0.95 }  -- time digits
local MAZE_RGBA  = { 0.84, 0.92, 0.98, 0.35 }  -- hex maze watermark, whisper blue (alpha 0 = off)
local MAZE_R     = 65                          -- watermark fit radius
local MAZE_LINE  = 1                           -- outline width; 0 = solid fill

-- Random dot field behind everything, à la polycore's MemoryGrid: a shuffled
-- grid of tiny squares in three brightness tiers. Positions fixed at load.
local DOTS_RGB   = { 0.40, 1.00, 1.00 }        -- polycore graph cyan-blue
local DOTS_ALPHA = 0.50                        -- brightest tier alpha; 0 = off
local DOTS_R     = 32                          -- scatter radius (design px); inside hour ring (r 34, width 2)
local DOTS_SIZE  = 2                           -- square edge (design px)
local DOTS_GAP   = 1                           -- space between squares
local DOTS_TWINKLE = 8                         -- mean twinkle period, seconds; 0 = static

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

-- ── Random dot field (built once at load; brightness twinkles per frame) ─────
-- Grid cells inside a DOTS_R circle, Fisher-Yates shuffled, then assigned
-- bright/mid/faint tiers like MemoryGrid plus a per-dot twinkle phase/speed.
-- Each cell: { x, y, base_brightness, phase, speed }
local DOTS = (function()
    math.randomseed(os.time())
    local cells, step = {}, DOTS_SIZE + DOTS_GAP
    for x = -DOTS_R, DOTS_R, step do
        for y = -DOTS_R, DOTS_R, step do
            -- keep a cell only if its whole square fits inside the circle:
            -- test the corner farthest from center ((x,y) is the top-left)
            local fx = math.max(math.abs(x), math.abs(x + DOTS_SIZE))
            local fy = math.max(math.abs(y), math.abs(y + DOTS_SIZE))
            if fx * fx + fy * fy <= DOTS_R * DOTS_R then
                cells[#cells + 1] = { x, y }
            end
        end
    end
    for i = #cells, 2, -1 do
        local j = math.random(i)
        cells[i], cells[j] = cells[j], cells[i]
    end
    -- tier fractions of the shuffled list, brightness relative to DOTS_ALPHA
    local tiers = { { 0.12, 1.00 }, { 0.22, 0.45 }, { 1.00, 0.12 } }
    local ti = 1
    for i, c in ipairs(cells) do
        while i > math.floor(#cells * tiers[ti][1] + 0.5) do ti = ti + 1 end
        c[3] = tiers[ti][2]
        c[4] = math.random() * 2 * math.pi     -- twinkle phase
        c[5] = 0.75 + math.random() * 0.5      -- twinkle speed jitter (±25%)
    end
    return cells
end)()

-- ─────────────────────────────────────────────────────────────────────────────

local function set_rgba(cr, c)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], c[4] or 1)
end

-- ── Hex maze icon (enigma logo, ported from nsd2.lua; caller sets color) ──────
-- SVG dimensions from enigma-logo2.lua; maze paths end at ~Y(180).

local SVG_W = 210.02
local SVG_H = 219.95

local function draw_hex_maze(cr, ix, iy, iw, ih, stroke_w)
    local function X(x) return ix + x * iw / SVG_W end
    local function Y(y) return iy + y * ih / SVG_H end
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
    if stroke_w and stroke_w > 0 then
        cairo_set_line_width(cr, stroke_w)
        cairo_stroke(cr)
    else
        cairo_fill(cr)
    end
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

    -- ── Random dot field (behind everything) ─────────────────────────────────
    if DOTS_ALPHA > 0 then
        local r, g, b = DOTS_RGB[1], DOTS_RGB[2], DOTS_RGB[3]
        cairo_set_antialias(cr, CAIRO_ANTIALIAS_NONE)
        -- monotonic clock drives the twinkle; phase is random so origin is moot
        local t = (DOTS_TWINKLE > 0) and (read_uptime() or os.time()) or 0
        for _, d in ipairs(DOTS) do
            local a = d[3]
            if DOTS_TWINKLE > 0 then
                -- slow sine fade between 10% and 100% of base brightness
                local omega = 2 * math.pi * d[5] / DOTS_TWINKLE
                a = a * (0.55 + 0.45 * math.sin(t * omega + d[4]))
            end
            cairo_set_source_rgba(cr, r, g, b, DOTS_ALPHA * a)
            cairo_rectangle(cr, cx + d[1] * s, cy + d[2] * s,
                            DOTS_SIZE * s, DOTS_SIZE * s)
            cairo_fill(cr)
        end
        cairo_set_antialias(cr, CAIRO_ANTIALIAS_DEFAULT)
    end

    -- ── Hex maze watermark (behind the digital time) ─────────────────────────
    if (MAZE_RGBA[4] or 0) > 0 then
        -- maze paths fit a circle of ~90 SVG units centered at (105, 90)
        local k = MAZE_R * s / 90
        set_rgba(cr, MAZE_RGBA)
        draw_hex_maze(cr, cx - k * SVG_W / 2, cy - k * 90, k * SVG_W, k * SVG_H,
                      MAZE_LINE * s)
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
    local ext = cairo_text_extents_t:create(); tolua.takeownership(ext)
    cairo_select_font_face(cr, FONT,
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    for _, row in ipairs({ { time_txt, big, cy + 5 * s },
                           { ampm, small, cy + 15 * s } }) do
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

    local cs, owns = surface.get()
    if cs == nil then return end
    local cr = cairo_create(cs)
    clock(cr, conky_window.width, conky_window.height)
    cairo_destroy(cr)
    surface.put(cs, owns)
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
