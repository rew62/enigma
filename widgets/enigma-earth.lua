-- enigma-earth.lua - Earth globe widget, 150px Cairo edition (brightness via Lua, not ImageMagick)
-- Controls: Ctrl+left-click move, Ctrl+right-click kill
--
-- Self-contained: conky runs this same file once directly (as the -c config,
-- before lua_load fires) and once via its own lua_load. Lua functions are
-- defined first; conky.config/text are guarded by `if conky` so they only
-- run on the first (config-parse) pass, not the second (lua_load) pass,
-- when cairo bindings become available.
-- v1 2026-07-04 @rew62

local window, surface

if not conky then
    require 'cairo'
    pcall(require, 'cairo_xlib')  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds
    window  = require("window")  -- already try_require()'d by scripts/loadall.lua
    surface = require("surface")
end

local RC_DIR = debug.getinfo(1,'S').source:match("@?(.*/)") or "./"
local ENIGMA_DIR = RC_DIR .. "../"

local IMG_PATH   = "/dev/shm/conky/earth.png"
local SIZE       = 150
local MARGIN     = 2

-- Tuning knobs
local BRIGHTNESS = 0.12   -- ADD-blend white alpha: 0=off, 0.25=strong lift
local CLIP_GLOBE = true   -- clip to circle so black corners never show

-- CAIRO_OPERATOR_ADD (12) is a base Cairo constant; define numerically in case
-- the Lua binding omits the name (SCREEN/MULTIPLY etc. are often not exposed)
local OP_ADD = CAIRO_OPERATOR_ADD or 12

-- ─── helpers ────────────────────────────────────────────────────────────────

local function draw_globe(cr)
    local img = cairo_image_surface_create_from_png(IMG_PATH)
    if cairo_surface_status(img) ~= 0 then   -- 0 = CAIRO_STATUS_SUCCESS
        cairo_surface_destroy(img)
        return
    end

    local iw = cairo_image_surface_get_width(img)
    local ih = cairo_image_surface_get_height(img)
    local x, y = MARGIN, MARGIN
    local w, h = SIZE - MARGIN * 2, SIZE - MARGIN * 2

    cairo_save(cr)

    if CLIP_GLOBE then
        cairo_arc(cr, x + w / 2, y + h / 2, w / 2, 0, 2 * math.pi)
        cairo_clip(cr)
    end

    cairo_translate(cr, x, y)
    cairo_scale(cr, w / iw, h / ih)

    cairo_set_source_surface(cr, img, 0, 0)
    cairo_paint(cr)

    -- brightness lift: additive white overlay
    if BRIGHTNESS > 0 then
        cairo_set_operator(cr, OP_ADD)
        cairo_set_source_rgba(cr, 1, 1, 1, BRIGHTNESS)
        cairo_rectangle(cr, 0, 0, iw, ih)
        cairo_fill(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
    end

    cairo_restore(cr)
    cairo_surface_destroy(img)
end

local function draw_timestamp(cr)
    local fh = io.popen("date -r " .. IMG_PATH .. ' "+%-m/%-d %-I:%M%p" 2>/dev/null')
    if not fh then return end
    local label = fh:read("*l") or ""
    fh:close()
    label = label:gsub("AM", "a"):gsub("PM", "p")
    if label == "" then return end

    cairo_select_font_face(cr, "MonaspiceNe Nerd Font Mono",
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 8)

    local te = cairo_text_extents_t:create()
    tolua.takeownership(te)
    cairo_text_extents(cr, label, te)

    cairo_set_source_rgba(cr, 0.7, 0.7, 0.7, 0.85)

    cairo_save(cr)
    -- horizontal reach of the rotated text is te.width*cos(45°), not te.width
    cairo_translate(cr, SIZE - te.width * math.cos(math.pi / 4) - 3, SIZE - 1)
    cairo_rotate(cr, -math.pi / 4)   -- 45° counterclockwise
    cairo_move_to(cr, 0, 0)
    cairo_show_text(cr, label)
    cairo_restore(cr)
end

-- ─── mouse hook ─────────────────────────────────────────────────────────────

function conky_mouse_hook(event)
    return window.handle_mouse(event)
end

-- ─── entry point ────────────────────────────────────────────────────────────

function conky_draw_earth2()
    if conky_window == nil then return end
    local cs, owns = surface.get()
    if cs == nil then return end
    local cr = cairo_create(cs)

    draw_globe(cr)
    draw_timestamp(cr)

    cairo_destroy(cr)
    surface.put(cs, owns)

    log_window_size()
end

-- ─────────────────────────────────────────────────────────────────────────────

if conky then
    conky.config = {

    -- Window
        background             = false,
        own_window             = true,
        own_window_type        = 'normal',
        own_window_transparent = true,
        own_window_argb_visual = true,
        own_window_argb_value  = 0,
        own_window_class       = 'Conky',
        own_window_title       = 'earth2',
        own_window_hints       = 'undecorated,sticky,skip_taskbar,skip_pager,below',

    -- Size & position (placeholder — adjust in etmux)
        alignment              = 'top_right',
        gap_x                  = 390,
        gap_y                  = 225,
        minimum_width          = 150,
        minimum_height         = 150,
        maximum_width          = 150,

    -- Rendering
        double_buffer          = true,
        update_interval        = 10,
        imlib_cache_size       = 0,   -- no cache; image changes every 10 min

    -- Text
        use_xft                = true,
        override_utf8_locale   = true,
        out_to_console         = false,
        extra_newline          = false,

    -- Misc
        draw_shades            = false,
        draw_borders           = false,
        draw_graph_borders     = false,
        draw_outline           = false,

    -- Lua
        lua_load               = ENIGMA_DIR .. 'settings.lua ' .. ENIGMA_DIR .. 'scripts/loadall.lua ' .. RC_DIR .. 'enigma-earth.lua',
        lua_draw_hook_post     = 'draw_earth2',
        lua_mouse_hook         = 'mouse_hook',
    }

    conky.text = [[]]
end
