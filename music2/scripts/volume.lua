-- scripts/volume.lua
-- Volume section: label, progress bar, mute/vol icons
-- Called from loadall.lua with a shared Cairo context
-- v1 2026-07-04 @rew62

local function rgb_to_rgba(color, alpha)
    return ((color / 0x10000) % 0x100) / 255,
           ((color / 0x100)   % 0x100) / 255,
           (color              % 0x100) / 255,
           alpha
end

local function exec_cmd(cmd)
    local h = io.popen(cmd)
    local r = h:read("*a")
    h:close()
    return r
end

-- both pactl queries in one popen; volume line arrives first, then "Mute: ..."
local function get_volume_state()
    local raw = exec_cmd("pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null; " ..
                         "pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null")
    local pct = tonumber(raw:match("(%d+)%%")) or 0
    return pct, raw:match("Mute:%s*yes") ~= nil
end

local function write_text(cr, x, y, text, f)
    f = f or {}
    local font   = f.font  or "Droid Sans"
    local size   = f.size  or 10
    local align  = f.align or 'l'
    local color  = f.color or 0xffffff
    local alpha  = f.alpha or 1.0

    local te = cairo_text_extents_t:create()
    tolua.takeownership(te)
    cairo_select_font_face(cr, font, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    cairo_text_extents(cr, text, te)

    local x_a = 0
    if align == 'r' then x_a = -(te.width + te.x_bearing) end
    if align == 'c' then x_a = -(te.width / 2 + te.x_bearing) end

    -- shadow
    cairo_set_source_rgba(cr, 0, 0, 0, 0.8)
    cairo_move_to(cr, x + 1 + x_a, y + 1)
    cairo_show_text(cr, text)
    cairo_stroke(cr)
    -- main
    cairo_set_source_rgba(cr, rgb_to_rgba(color, alpha))
    cairo_move_to(cr, x + x_a, y)
    cairo_show_text(cr, text)
    cairo_stroke(cr)
end

-- Draw a PNG icon scaled to icon_size×icon_size
local function draw_icon(cr, path, x, y, icon_size)
    local f = io.open(path, "r")
    if not f then return end
    f:close()
    local img = cairo_image_surface_create_from_png(path)
    local iw  = cairo_image_surface_get_width(img)
    local ih  = cairo_image_surface_get_height(img)
    if iw == 0 or ih == 0 then cairo_surface_destroy(img); return end
    cairo_save(cr)
    cairo_translate(cr, x, y)
    cairo_scale(cr, icon_size / iw, icon_size / ih)
    cairo_set_source_surface(cr, img, 0, 0)
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
    cairo_paint(cr)
    cairo_restore(cr)
    cairo_surface_destroy(img)
    collectgarbage()
end

-- Draw a speaker icon in Cairo when PNG icons aren't available
local function draw_speaker_cairo(cr, x, y, size, muted)
    local s = size / 20  -- scale factor

    -- Speaker body
    if muted then
        cairo_set_source_rgba(cr, 0.8, 0.3, 0.3, 0.9)
    else
        cairo_set_source_rgba(cr, 0.6, 0.9, 0.6, 0.9)
    end

    -- Box part of speaker
    cairo_rectangle(cr, x, y + size * 0.3, size * 0.4, size * 0.4)
    cairo_fill(cr)

    -- Triangle cone
    cairo_move_to(cr, x + size * 0.4, y + size * 0.3)
    cairo_line_to(cr, x + size * 0.8, y)
    cairo_line_to(cr, x + size * 0.8, y + size)
    cairo_line_to(cr, x + size * 0.4, y + size * 0.7)
    cairo_close_path(cr)
    cairo_fill(cr)

    if muted then
        -- X mark
        cairo_set_source_rgba(cr, 1, 0.2, 0.2, 1)
        cairo_set_line_width(cr, 2 * s)
        cairo_move_to(cr, x + size * 0.85, y + size * 0.2)
        cairo_line_to(cr, x + size,        y + size * 0.8)
        cairo_stroke(cr)
        cairo_move_to(cr, x + size,        y + size * 0.2)
        cairo_line_to(cr, x + size * 0.85, y + size * 0.8)
        cairo_stroke(cr)
    else
        -- Sound arcs
        cairo_set_source_rgba(cr, 0.6, 0.9, 0.6, 0.7)
        cairo_set_line_width(cr, 1.5 * s)
        cairo_arc(cr, x + size * 0.5, y + size * 0.5, size * 0.4, -math.pi/3, math.pi/3)
        cairo_stroke(cr)
        cairo_arc(cr, x + size * 0.5, y + size * 0.5, size * 0.65, -math.pi/3, math.pi/3)
        cairo_stroke(cr)
    end
end

-- Draw the divider line between sections
local function draw_divider(cr, y, margin, width)
    cairo_set_line_width(cr, 1)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.12)
    cairo_move_to(cr, margin, y)
    cairo_line_to(cr, width - margin, y)
    cairo_stroke(cr)
end

-- ── public entry point ─────────────────────────────────────

-- y_off: top y of this section within the conky window
-- Layout: label+pct row, then a icon/bar/icon row (150px usable width,
-- bar is narrower than the old 340px version so the icons fit at the edges)
function draw_volume(cr, y_off)
    local vol_pct, muted = get_volume_state()
    local vol_str = string.format("%d%%", vol_pct)

    local win_w    = conky_window and conky_window.width or 154
    local margin   = 2
    local icon_sz  = 16

    local bar_x   = margin + icon_sz + 4
    local bar_end = win_w - margin - icon_sz - 4
    local bar_w   = bar_end - bar_x
    local bar_h   = 6

    local row_cy  = y_off + 26          -- icon/bar row center
    local icon_y  = row_cy - icon_sz / 2
    local bar_y   = row_cy - bar_h / 2

    -- Divider above section
    draw_divider(cr, y_off - 6, margin, win_w)

    -- Section label + percentage (full usable width)
    write_text(cr, margin,         y_off + 8, "Volume",
        {font="Droid Sans", size=10, color=0x8dddff})
    write_text(cr, win_w - margin, y_off + 8, vol_str,
        {font="Droid Sans", size=10, color=0xffffff, align="r"})

    -- Bar background
    cairo_rectangle(cr, bar_x, bar_y, bar_w, bar_h)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.2)
    cairo_fill(cr)

    -- Bar fill (green when normal, red when muted)
    local fill_color = muted and 0xff4444 or 0x4caf50
    local fill_alpha = muted and 0.7 or 1.0
    cairo_rectangle(cr, bar_x, bar_y, bar_w * (vol_pct / 100), bar_h)
    cairo_set_source_rgba(cr, rgb_to_rgba(fill_color, fill_alpha))
    cairo_fill(cr)

    -- Mute/vol icons, flush against the left/right edges
    local mute_icon = "./images/mute.png"
    local vol_icon  = "./images/vol.png"

    local f = io.open(mute_icon, "r")
    if f then
        f:close()
        draw_icon(cr, mute_icon, margin,                    icon_y, icon_sz)
        draw_icon(cr, vol_icon,  win_w - margin - icon_sz,  icon_y, icon_sz)
    else
        -- Fallback: draw speaker icons in Cairo
        draw_speaker_cairo(cr, margin,                   icon_y, icon_sz, true)
        draw_speaker_cairo(cr, win_w - margin - icon_sz, icon_y, icon_sz, false)
    end

    -- Muted overlay text
    if muted then
        write_text(cr, win_w / 2, row_cy + 18, "MUTED",
            {font="Droid Sans", size=9, align="c", color=0xff4444, alpha=0.9})
    end
end

