-- draw_nws_forecast_small.lua - 150px 3-day forecast strip
-- Day / Date / Icon / High / Low per cell; no footer
-- v1 2026-07-04 @rew62

require 'cairo'
pcall(require, 'cairo_xlib')  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

package.path = package.path .. ";./?.lua;../?.lua;"
    .. (os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma") .. "/scripts/?.lua"

local surface = require("surface")

local cjson = nil
local ok, lib = pcall(require, "cjson")
if ok then
    cjson = lib
else
    local ok2, lib2 = pcall(require, "json")
    if ok2 then
        cjson = lib2
        print("cjson not found, using scripts/json.lua fallback.")
    else
        print("FATAL: no JSON library found")
    end
end

-- -----------------------------------------------------------------------
-- CONFIG
-- -----------------------------------------------------------------------

local CFG = {
    WIDGET_W  = 150,
    WIDGET_H  = 86,
    NUM_DAYS  = 4,

    OFFSET_X  = 2,
    OFFSET_Y  = 4,
    GUTTER    = 14,  -- 6.5px pad + 1px divider + 6.5px pad between columns

    FONT      = "Roboto",

    SIZE_DAY  = 9,
    SIZE_DATE = 8,
    SIZE_TEMP = 11,
    ICON_PX   = 22,

    DRAW_BG   = false,
    BG_R      = 6,
}

local COL_DAY  = { 0.85, 0.85, 0.85, 1.00 }
local COL_DATE = { 0.55, 0.55, 0.55, 1.00 }
local COL_HIGH = { 1.00, 0.65, 0.20, 1.00 }
local COL_LOW  = { 0.35, 0.75, 1.00, 1.00 }
local COL_BG   = { 0.05, 0.07, 0.12, 0.55 }
local COL_DIV  = { 1.00, 1.00, 1.00, 0.10 }

-- -----------------------------------------------------------------------
-- ICON HELPERS
-- -----------------------------------------------------------------------

local ICON_DIR   = "/dev/shm/conky/icons/"
local METNO_BASE = "https://cdn.jsdelivr.net/gh/metno/weathericons@main/weather/png/"

local _mtime_cache   = nil
local _mtime_checked = 0

do
    os.execute("mkdir -p " .. ICON_DIR)
    local h = io.popen("stat -c %Y /dev/shm/conky/nws_forecast.json 2>/dev/null")
    if h then
        _mtime_cache   = tonumber(h:read("*l"))
        _mtime_checked = os.time()
        h:close()
    end
end

local NWS_TO_METNO = {
    clear                  = "clearsky_day",
    clear_day              = "clearsky_day",
    clear_night            = "clearsky_night",
    few_clouds             = "clearsky_day",
    few_clouds_day         = "fair_day",
    few_clouds_night       = "fair_night",
    scattered_clouds       = "partlycloudy_day",
    scattered_clouds_day   = "partlycloudy_day",
    scattered_clouds_night = "partlycloudy_night",
    broken_clouds          = "cloudy",
    broken_clouds_day      = "cloudy",
    broken_clouds_night    = "cloudy",
    overcast               = "cloudy",
    overcast_day           = "cloudy",
    overcast_night         = "cloudy",
    rain                   = "rain",
    showers                = "rainshowers_day",
    showers_day            = "rainshowers_day",
    showers_night          = "rainshowers_night",
    snow                   = "snow",
    sleet                  = "sleet",
    freezing_rain          = "sleet",
    blizzard               = "heavysnow",
    thunderstorm           = "rainandthunder",
    thunderstorm_day       = "rainandthunder",
    thunderstorm_night     = "rainandthunder",
    windy                  = "partlycloudy_day",
    windy_clouds           = "partlycloudy_day",
    windy_overcast         = "cloudy",
    fog                    = "fog",
    haze                   = "fog",
    haze_day               = "fog",
    haze_night             = "fog",
    smoke                  = "fog",
    dust                   = "fog",
    tornado                = "rainandthunder",
    hurricane              = "rainandthunder",
    tropical_storm         = "rainandthunder",
    hot                    = "clearsky_day",
    cold                   = "clearsky_day",
}

local function fetch_metno_icon(name)
    local path = ICON_DIR .. "metno_" .. name .. ".png"
    local fh = io.open(path, "r")
    if fh then fh:close(); return path end
    os.execute(string.format('curl -sfL "%s" -o "%s" &', METNO_BASE .. name .. ".png", path))
    local fallback = ICON_DIR .. "metno_clearsky_day.png"
    local fb = io.open(fallback, "r")
    if fb then fb:close(); return fallback end
    return path
end

local function nws_icon_path(token)
    if not token or token == "" then return fetch_metno_icon("clearsky_day") end
    local name = NWS_TO_METNO[token]
               or NWS_TO_METNO[token:gsub("_day$",""):gsub("_night$","")]
               or "partlycloudy_day"
    return fetch_metno_icon(name)
end

-- -----------------------------------------------------------------------
-- DRAWING HELPERS
-- -----------------------------------------------------------------------

local function set_col(cr, c)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], c[4])
end

local function draw_centered(cr, text, cx, y, size, col, bold)
    cairo_select_font_face(cr, CFG.FONT,
        CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    set_col(cr, col)
    local ext = cairo_text_extents_t:create(); tolua.takeownership(ext)
    cairo_text_extents(cr, tostring(text), ext)
    cairo_move_to(cr, cx - (ext.width / 2 + ext.x_bearing), y)
    cairo_show_text(cr, tostring(text))
end

local function draw_image(cr, path, x, y, w, h)
    local surf = cairo_image_surface_create_from_png(path)
    if cairo_surface_status(surf) ~= 0 then cairo_surface_destroy(surf); return end
    local iw = cairo_image_surface_get_width(surf)
    local ih = cairo_image_surface_get_height(surf)
    if iw == 0 or ih == 0 then cairo_surface_destroy(surf); return end
    cairo_save(cr)
    cairo_translate(cr, x, y)
    cairo_scale(cr, w / iw, h / ih)
    cairo_set_source_surface(cr, surf, 0, 0)
    cairo_paint(cr)
    cairo_restore(cr)
    cairo_surface_destroy(surf)
end

local function rounded_rect(cr, x, y, w, h, r)
    if r <= 0 then cairo_rectangle(cr, x, y, w, h); return end
    local pi = math.pi
    cairo_new_sub_path(cr)
    cairo_arc(cr, x+w-r, y+r,   r, -pi/2, 0)
    cairo_arc(cr, x+w-r, y+h-r, r,  0,    pi/2)
    cairo_arc(cr, x+r,   y+h-r, r,  pi/2, pi)
    cairo_arc(cr, x+r,   y+r,   r,  pi,   3*pi/2)
    cairo_close_path(cr)
end

-- -----------------------------------------------------------------------
-- MAIN DRAW
-- -----------------------------------------------------------------------

local MONTHS = {"Jan","Feb","Mar","Apr","May","Jun",
                "Jul","Aug","Sep","Oct","Nov","Dec"}

local function do_draw(cr)
    local fc = get_forecast()
    if not fc or #fc == 0 then
        weather_update()
        fc = get_forecast() or {}
    end

    local W  = CFG.WIDGET_W
    local H  = CFG.WIDGET_H
    local ox = CFG.OFFSET_X
    local oy = CFG.OFFSET_Y
    local N  = math.min(CFG.NUM_DAYS, #fc)
    if N == 0 then return end

    if CFG.DRAW_BG then
        set_col(cr, COL_BG)
        rounded_rect(cr, ox, oy, W, H, CFG.BG_R)
        cairo_fill(cr)
    end

    local G      = CFG.GUTTER or 0
    local cell_w = (W - (N - 1) * G) / N
    local icon   = CFG.ICON_PX

    -- Proportional vertical layout within H
    local pad  = H * 0.05
    local span = H - pad * 2

    local y_day  = oy + pad + span * 0.12   -- day name baseline
    local y_date = oy + pad + span * 0.28   -- date baseline
    local y_icon = oy + pad + span * 0.32   -- icon top
    local y_high = oy + pad + span * 0.76   -- high temp baseline
    local y_low  = oy + pad + span * 0.94   -- low temp baseline

    for i = 1, N do
        local d  = fc[i]
        local cx = ox + (i - 1) * (cell_w + G) + cell_w / 2

        -- Day abbreviation
        local dow = (d.dow or ""):gsub("^%l", string.upper)
        if     dow:lower():find("tonight")        then dow = "Tnt"
        elseif dow:lower():find("this afternoon") then dow = "Aft"
        elseif dow:lower():find("today")          then dow = "Today"
        else   dow = dow:sub(1, 3)
        end

        -- Date "Jun 12"
        local date_str = ""
        if d.date and d.date ~= "" then
            local _, m, day = d.date:match("(%d%d%d%d)-(%d%d)-(%d%d)")
            if m then
                date_str = MONTHS[tonumber(m)] .. " " .. tostring(tonumber(day))
            end
        end

        -- Temps
        local hi_str = d.temp_high and (tostring(d.temp_high) .. "°") or "--"
        local lo_str = d.temp_low  and (tostring(d.temp_low)  .. "°") or "--"

        draw_centered(cr, dow,      cx, y_day,  CFG.SIZE_DAY,  COL_DAY,  true)
        draw_centered(cr, date_str, cx, y_date, CFG.SIZE_DATE, COL_DATE, false)
        draw_image(cr, nws_icon_path(d.icon), cx - icon / 2, y_icon, icon, icon)
        draw_centered(cr, hi_str,   cx, y_high, CFG.SIZE_TEMP, COL_HIGH, true)
        draw_centered(cr, lo_str,   cx, y_low,  CFG.SIZE_TEMP, COL_LOW,  false)

        -- Vertical divider centered in the 3px gutter between cells
        if i < N then
            local lx = math.floor(ox + i * (cell_w + G) - G / 2) + 0.5
            set_col(cr, COL_DIV)
            cairo_set_line_width(cr, 1)
            cairo_move_to(cr, lx, oy + H * 0.10)
            cairo_line_to(cr, lx, oy + H * 0.90)
            cairo_stroke(cr)
        end
    end
end

-- -----------------------------------------------------------------------
-- CONKY ENTRY POINT
-- -----------------------------------------------------------------------

function conky_weather_main()
    if conky_window == nil then return end
    local cs, owns = surface.get()
    if cs == nil then return end
    local cr = cairo_create(cs)
    local ok, err = pcall(do_draw, cr)
    if not ok then print("forecast-small draw error: " .. tostring(err)) end
    cairo_destroy(cr)
    surface.put(cs, owns)
end
