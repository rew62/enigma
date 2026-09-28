-- solar_dial3.lua  –  Apple Watch Solar face replica for Conky – 200 px dial + system meter ring
-- solar_dial2.lua with the outer readout ring from lua_orrery.lua wrapped around it:
-- CPU, MEM, CPU temp, ROOT and HOME as arcs coloured green → yellow → red by load,
-- labelled with text that follows the curve.
-- v1 2026-07-04 @rew62   (solar_dial3 2026-09-28)

if not conky then require 'cairo'; pcall(require, 'cairo_xlib') end  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local SCRIPT_DIR = debug.getinfo(1,'S').source:match("@?(.*/)" ) or "./"
local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma"
package.path = SCRIPT_DIR .. "?.lua;" .. SCRIPT_DIR .. "../scripts/?.lua;" .. package.path
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

-- ── Configuration ─────────────────────────────────────────────────────────
local C = {
    show_meters = true,   -- system meter ring on at startup; Shift+left-click toggles it

    lat = 40.7128, lon = -74.0060,   -- overridden by .env

    cx = 135, cy = 135,   -- window is 270 px: the 200 px dial plus the meter ring
    face_r  = 100,   -- outer edge of the dial  (diameter 200 px)
    ring_r  =  96,   -- outer edge of tick-mark bezel
    dial_r  =  84,   -- inner edge of tick band
    arc_r   =  60,   -- radius of the sun-path orbit  (3/5 of face_r)
    clock_r =  40,   -- central frosted clock disc radius  (2/5 of face_r)

    font = "DejaVu Sans",

    -- Meter ring (outside the dial)
    meter_r     = 110,   -- radius of the meter arcs
    meter_w     = 3.5,   -- arc thickness
    meter_gap   = 14,    -- degrees left empty between neighbouring meters
    meter_font  = 9,     -- size of the curved caption/value text
    meter_text_gap = 5,  -- space between the arc and the text band
    temp_max    = 100,   -- °C that fills the temperature arc

    -- Colour thresholds: green up to `ok`, fading to yellow by `warn`,
    -- to red by `crit`. Percent for load/disk, °C for temperature.
    load_levels = { ok = 50, warn = 75, crit = 90 },
    temp_levels = { ok = 55, warn = 70, crit = 85 },
}

-- ── .env loader ───────────────────────────────────────────────────────────
local env = try_require("env")
C.lat = tonumber(env.get("LAT")) or C.lat
C.lon = tonumber(env.get("LON")) or C.lon

-- ── Timezone offset (decimal hours from UTC) ──────────────────────────────
local function tz_offset()
    local z = os.date("%z") or "+0000"
    local sign = z:sub(1,1)=="-" and -1 or 1
    return sign*((tonumber(z:sub(2,3)) or 0)+(tonumber(z:sub(4,5)) or 0)/60)
end

-- ── Math helpers ──────────────────────────────────────────────────────────
local PI=math.pi; local TWO_PI=2*PI
local function rad(d)       return d*PI/180      end
local function deg(r)       return r*180/PI      end
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function lerp(a,b,t)  return a+(b-a)*t     end

-- Dial angle: noon (12h) at top (–π/2), clockwise.
local function h2a(h) return (h-12)/24*TWO_PI-PI/2 end

-- ── Theme ─────────────────────────────────────────────────────────────────
local THEME = "ghost"

local THEMES = {
    dark = {
        frosted_base  = false,
        annular_bezel = false,
        ring_rgba     = { 0.596, 0.984, 0.596, 1.0 },
        vignette      = { 0.45, 0.20, 0.00 },
        atm_alphas    = { 0.72, 0.25, 0.00, 0.00, 0.30, 0.60 },
        sky = function(alt)
            if    alt <  -18 then return 0.01, 0.01, 0.06, 0.85
            elseif alt < -12 then local t=(alt+18)/6
                return lerp(0.01,0.02,t), lerp(0.01,0.02,t), lerp(0.06,0.10,t), 0.85
            elseif alt <  -6 then local t=(alt+12)/6
                return lerp(0.02,0.06,t), lerp(0.02,0.03,t), lerp(0.10,0.12,t), 0.85
            elseif alt <   0 then local t=(alt+6)/6
                return lerp(0.06,0.22,t), lerp(0.03,0.10,t), lerp(0.12,0.05,t), 0.85
            elseif alt <   6 then local t=alt/6
                return lerp(0.22,0.40,t), lerp(0.10,0.22,t), lerp(0.05,0.05,t), 0.85
            elseif alt <  20 then local t=(alt-6)/14
                return lerp(0.40,0.14,t), lerp(0.22,0.26,t), lerp(0.05,0.40,t), 0.85
            else  return 0.04, 0.14, 0.38, 0.85
            end
        end,
    },
    light = {
        frosted_base  = true,
        annular_bezel = false,
        ring_rgba     = { 0.596, 0.984, 0.596, 1.0 },
        vignette      = { 0.35, 0.08, 0.00 },
        atm_alphas    = { 0.00, 0.00, 0.00, 0.00, 0.00, 0.00 },
        sky = function(alt)
            if    alt <  -18 then return 0.35, 0.38, 0.62, 0.80
            elseif alt < -12 then local t=(alt+18)/6
                return lerp(0.35,0.48,t), lerp(0.38,0.44,t), lerp(0.62,0.66,t), lerp(0.80,0.75,t)
            elseif alt <  -6 then local t=(alt+12)/6
                return lerp(0.48,0.65,t), lerp(0.44,0.48,t), lerp(0.66,0.60,t), lerp(0.75,0.70,t)
            elseif alt <   0 then local t=(alt+6)/6
                return lerp(0.65,0.88,t), lerp(0.48,0.62,t), lerp(0.60,0.48,t), lerp(0.70,0.62,t)
            elseif alt <   6 then local t=alt/6
                return lerp(0.88,0.72,t), lerp(0.62,0.78,t), lerp(0.48,0.56,t), lerp(0.62,0.58,t)
            else  return 0.52, 0.74, 0.92, 0.55
            end
        end,
    },
    ghost = {
        frosted_base  = false,
        annular_bezel = false,
        ring_rgba     = { 0.596, 0.984, 0.596, 1.0 },
        vignette      = { 0.40, 0.15, 0.00 },
        atm_alphas    = { 0.00, 0.00, 0.00, 0.00, 0.00, 0.00 },
        sky = function(alt)
            if    alt <  -18 then return 0.04, 0.06, 0.18, 0.78
            elseif alt < -12 then local t=(alt+18)/6
                return lerp(0.04,0.08,t), lerp(0.06,0.12,t), lerp(0.18,0.28,t), lerp(0.78,0.75,t)
            elseif alt <  -6 then local t=(alt+12)/6
                return lerp(0.08,0.14,t), lerp(0.12,0.20,t), lerp(0.28,0.44,t), lerp(0.75,0.68,t)
            elseif alt <   0 then local t=(alt+6)/6
                return lerp(0.14,0.28,t), lerp(0.20,0.42,t), lerp(0.44,0.72,t), lerp(0.68,0.48,t)
            elseif alt <   6 then local t=alt/6
                return lerp(0.28,0.52,t), lerp(0.42,0.70,t), lerp(0.72,0.96,t), lerp(0.48,0.10,t)
            else  return 0.52, 0.70, 0.96, 0.08
            end
        end,
    },
}

local T = THEMES[THEME]

-- ── Solar maths ───────────────────────────────────────────────────────────
local function jd(y,mo,d,utc)
    if mo<=2 then y=y-1; mo=mo+12 end
    local A=math.floor(y/100); local B=2-A+math.floor(A/4)
    return math.floor(365.25*(y+4716))+math.floor(30.6001*(mo+1))+d+B-1524.5+utc/24
end

local function sun_alt_at(y,mo,d,lh,tz)
    local utc=lh-tz; local dd,mm,yy=d,mo,y
    if utc>=24 then utc=utc-24; dd=dd+1 elseif utc<0 then utc=utc+24; dd=dd-1 end
    local n=jd(yy,mm,dd,utc)-2451545
    local L=math.fmod(280.46+0.9856474*n,360)
    local g=rad(math.fmod(357.528+0.9856003*n,360))
    local lam=rad(L+1.915*math.sin(g)+0.020*math.sin(2*g))
    local eps=rad(23.439-4e-7*n)
    local sin_dec=math.sin(eps)*math.sin(lam)
    local dec=math.asin(sin_dec)
    local RA=math.atan2(math.cos(eps)*math.sin(lam),math.cos(lam))
    local n0=jd(yy,mm,dd,0)-2451545
    local GMST=math.fmod(6.697375+0.0657098242*n0+utc*1.00273791,24)
    if GMST<0 then GMST=GMST+24 end
    local LMST=math.fmod(GMST+C.lon/15,24); if LMST<0 then LMST=LMST+24 end
    local HA=rad(LMST*15)-RA
    local lat=rad(C.lat)
    return deg(math.asin(math.sin(lat)*sin_dec+math.cos(lat)*math.cos(dec)*math.cos(HA)))
end

local function find_cross(y,mo,d,h0,h1,tz,rising)
    for _=1,52 do
        local m=(h0+h1)/2; local a=sun_alt_at(y,mo,d,m,tz)
        if rising then
            if a<-0.833 then h0=m else h1=m end
        else
            if a>-0.833 then h0=m else h1=m end
        end
        if h1-h0<3e-4 then break end
    end
    return (h0+h1)/2
end

local function solar_events(y,mo,d,tz)
    local best,noon=-999,12
    for i=0,200 do local h=6+i*0.06; local a=sun_alt_at(y,mo,d,h,tz); if a>best then best=a; noon=h end end
    local sr,ss
    if sun_alt_at(y,mo,d,0.01,tz)<-0.833 and best>-0.833 then sr=find_cross(y,mo,d,0,noon,tz,true) end
    if best>-0.833 and sun_alt_at(y,mo,d,23.99,tz)<-0.833 then ss=find_cross(y,mo,d,noon,24,tz,false) end
    return {sunrise=sr,sunset=ss,noon=noon,noon_alt=best}
end

local _ev={day=-1}
local function get_events(y,mo,d,tz)
    if _ev.day~=d then _ev.ev=solar_events(y,mo,d,tz); _ev.day=d end
    return _ev.ev
end

-- ── Sky fill ──────────────────────────────────────────────────────────────
local function alt_to_sector_color(alt) return T.sky(alt) end

local function draw_sky(cr, y, mo, d, tz)
    local cx,cy,r = C.cx,C.cy,C.face_r
    local SEGS = 240

    cairo_save(cr)
    cairo_arc(cr,cx,cy,r,0,TWO_PI)
    cairo_clip(cr)

    if T.frosted_base then
        local fg = cairo_pattern_create_radial(cx, cy, r*0.40, cx, cy, r)
        cairo_pattern_add_color_stop_rgba(fg, 0.0, 0.95, 0.97, 1.0, 0.90)
        cairo_pattern_add_color_stop_rgba(fg, 0.7, 0.95, 0.97, 1.0, 0.82)
        cairo_pattern_add_color_stop_rgba(fg, 1.0, 0.95, 0.97, 1.0, 0.00)
        cairo_arc(cr, cx, cy, r, 0, TWO_PI)
        cairo_set_source(cr, fg); cairo_fill(cr); cairo_pattern_destroy(fg)
    end

    for i=0, SEGS-1 do
        local h_mid = (i+0.5)/SEGS * 24
        local a1    = h2a(i    /SEGS * 24)
        local a2    = h2a((i+1)/SEGS * 24)
        local alt   = sun_alt_at(y,mo,d, h_mid, tz)
        local sr,sg,sb,sa = alt_to_sector_color(alt)

        cairo_move_to(cr, cx, cy)
        cairo_arc(cr, cx, cy, r, a1, a2)
        cairo_close_path(cr)
        cairo_set_source_rgba(cr, sr, sg, sb, sa)
        cairo_fill(cr)
    end

    local aa = T.atm_alphas
    local atm = cairo_pattern_create_linear(cx, cy-r, cx, cy+r)
    cairo_pattern_add_color_stop_rgba(atm, 0.00, 0.00, 0.00, 0.18, aa[1])
    cairo_pattern_add_color_stop_rgba(atm, 0.28, 0.00, 0.00, 0.10, aa[2])
    cairo_pattern_add_color_stop_rgba(atm, 0.45, 0.00, 0.00, 0.00, aa[3])
    cairo_pattern_add_color_stop_rgba(atm, 0.55, 0.00, 0.00, 0.00, aa[4])
    cairo_pattern_add_color_stop_rgba(atm, 0.72, 0.00, 0.00, 0.00, aa[5])
    cairo_pattern_add_color_stop_rgba(atm, 1.00, 0.00, 0.00, 0.00, aa[6])
    cairo_set_source(cr, atm); cairo_paint(cr); cairo_pattern_destroy(atm)

    local vi = T.vignette
    local vg = cairo_pattern_create_radial(cx,cy, r*vi[1], cx,cy, r)
    cairo_pattern_add_color_stop_rgba(vg, 0.0, 0,0,0, 0)
    cairo_pattern_add_color_stop_rgba(vg, 0.6, 0,0,0, vi[2])
    cairo_pattern_add_color_stop_rgba(vg, 1.0, 0,0,0, vi[3])
    cairo_set_source(cr, vg); cairo_paint(cr); cairo_pattern_destroy(vg)

    cairo_restore(cr)
end

-- ── Text centred on (x,y) ─────────────────────────────────────────────────
local function textc(cr,txt,x,y,font,size,weight,r,g,b,a)
    cairo_select_font_face(cr,font,CAIRO_FONT_SLANT_NORMAL,weight)
    cairo_set_font_size(cr,size)
    local te=cairo_text_extents_t:create(); tolua.takeownership(te)
    cairo_text_extents(cr,txt,te)
    cairo_move_to(cr, x-te.width/2-te.x_bearing, y-te.height/2-te.y_bearing)
    cairo_set_source_rgba(cr,r,g,b,a)
    cairo_show_text(cr,txt)
end

local function fmth(dh)
    local h=math.floor(dh); local m=math.floor((dh-h)*60+0.5)
    if m==60 then h=h+1;m=0 end
    h=h%24
    local suffix=h<12 and "a" or "p"
    local h12=h%12; if h12==0 then h12=12 end
    return string.format("%d:%02d%s",h12,m,suffix)
end

-- ── Meter ring: readings ──────────────────────────────────────────────────
local function num(v, default) return tonumber(v) or default end

local function read_line(path)
    local f = io.open(path, "r"); if not f then return nil end
    local l = f:read("*l"); f:close(); return l
end

-- Whole-CPU temperature: Intel "Package id 0", AMD Tctl/Tdie, else temp1 of
-- the CPU chip. Found once; retried every 30 s if the sensors aren't up yet.
local _temp_path, _temp_retry = nil, 0
local function cpu_temp()
    if not _temp_path and os.time() >= _temp_retry then
        _temp_retry = os.time() + 30
        for chip = 0, 31 do
            local dir = "/sys/class/hwmon/hwmon" .. chip .. "/"
            local name = read_line(dir .. "name")
            if name == "coretemp" or name == "k10temp" or name == "zenpower" then
                for i = 1, 99 do
                    local lbl = read_line(dir .. "temp" .. i .. "_label")
                    if lbl == "Package id 0" or lbl == "Tctl" or lbl == "Tdie" then
                        _temp_path = dir .. "temp" .. i .. "_input"; break
                    end
                end
                _temp_path = _temp_path or dir .. "temp1_input"
                break
            end
        end
    end
    return _temp_path and num(read_line(_temp_path), 0) / 1000 or 0
end

-- ── Meter ring: colour ────────────────────────────────────────────────────
local GREEN  = { 0.30, 0.85, 0.40 }
local YELLOW = { 1.00, 0.84, 0.20 }
local RED    = { 1.00, 0.30, 0.25 }

local function mixc(a, b, t)
    return { lerp(a[1],b[1],t), lerp(a[2],b[2],t), lerp(a[3],b[3],t) }
end

-- Green until lv.ok, blend to yellow by lv.warn, then to red by lv.crit.
local function level_color(v, lv)
    if v <= lv.ok   then return GREEN end
    if v <= lv.warn then return mixc(GREEN,  YELLOW, (v - lv.ok)   / (lv.warn - lv.ok)) end
    if v <= lv.crit then return mixc(YELLOW, RED,    (v - lv.warn) / (lv.crit - lv.warn)) end
    return RED
end

-- ── Meter ring: text along an arc ─────────────────────────────────────────
local _adv = {}
local function advance(cr, ch, key)
    local k = key .. ch
    if not _adv[k] then
        local te = cairo_text_extents_t:create(); tolua.takeownership(te)
        cairo_text_extents(cr, ch, te)
        _adv[k] = te.x_advance
    end
    return _adv[k]
end

-- Draws `runs` ({text, weight, {r,g,b}, alpha}, ...) centred on angle `mid`
-- in the band just outside radius r. On the upper half the text reads
-- clockwise with letters standing outward; on the lower half it reads
-- anticlockwise with letters hanging inward, so both read left to right.
local function arc_text(cr, runs, mid, r, size)
    local cap   = size * 0.73                      -- DejaVu cap height
    local r_mid = r + cap / 2                      -- spacing measured mid-band
    local lower = math.sin(mid) > 0
    local dir   = lower and -1 or 1
    local base  = lower and (r + cap) or r         -- baseline radius

    cairo_set_font_size(cr, size)
    local glyphs, width = {}, 0
    for _, run in ipairs(runs) do
        cairo_select_font_face(cr, C.font, CAIRO_FONT_SLANT_NORMAL, run[2])
        for ch in run[1]:gmatch("[\1-\127\194-\244][\128-\191]*") do
            local w = advance(cr, ch, size .. ":" .. run[2] .. ":")
            glyphs[#glyphs+1] = { ch, w, run }
            width = width + w
        end
    end

    local start, x = mid - dir * width / (2 * r_mid), 0
    for _, g in ipairs(glyphs) do
        local ch, w, run = g[1], g[2], g[3]
        local a = start + dir * (x + w / 2) / r_mid
        cairo_select_font_face(cr, C.font, CAIRO_FONT_SLANT_NORMAL, run[2])
        cairo_set_source_rgba(cr, run[3][1], run[3][2], run[3][3], run[4])
        cairo_save(cr)
        cairo_translate(cr, C.cx + base * math.cos(a), C.cy + base * math.sin(a))
        cairo_rotate(cr, a + dir * PI / 2)
        cairo_move_to(cr, -w / 2, 0)
        cairo_show_text(cr, ch)
        cairo_restore(cr)
        x = x + w
    end
end

-- ── Meter ring: arcs ──────────────────────────────────────────────────────
local WHITE = { 1, 1, 1 }

-- One meter centred on angle `mid`, `span` radians wide. The fill starts at
-- the end the label is read from, so lower meters fill right-to-left along
-- the arc but still grow in the reading direction.
local function draw_meter(cr, mid, span, fraction, color, caption, value)
    local r = C.meter_r
    local a0, a1 = mid - span / 2, mid + span / 2
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, C.meter_w)

    cairo_new_path(cr)
    cairo_arc(cr, C.cx, C.cy, r, a0, a1)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.15)
    cairo_stroke(cr)

    fraction = clamp(fraction, 0, 1)
    if fraction > 0 then
        cairo_new_path(cr)
        if math.sin(mid) > 0 then
            cairo_arc_negative(cr, C.cx, C.cy, r, a1, a1 - span * fraction)
        else
            cairo_arc(cr, C.cx, C.cy, r, a0, a0 + span * fraction)
        end
        cairo_set_source_rgba(cr, color[1], color[2], color[3], 0.95)
        cairo_stroke(cr)
    end
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)

    arc_text(cr, {
        { caption .. " ", CAIRO_FONT_WEIGHT_NORMAL, WHITE, 0.70 },
        { value,          CAIRO_FONT_WEIGHT_BOLD,   color, 0.95 },
    }, mid, r + C.meter_w / 2 + C.meter_text_gap, C.meter_font)
end

local function draw_meters(cr)
    local cpu  = num(conky_parse("${cpu cpu0}"), 0)
    local mem  = num(conky_parse("${memperc}"), 0)
    local temp = cpu_temp()
    local root = num(conky_parse("${fs_used_perc /}"), 0)
    local home = num(conky_parse("${fs_used_perc /home}"), 0)
    local L, TL = C.load_levels, C.temp_levels
    local function pct(v) return string.format("%d%%", math.floor(v + 0.5)) end

    local meters = {
        { "CPU",  cpu / 100,        level_color(cpu,  L),  pct(cpu) },
        { "MEM",  mem / 100,        level_color(mem,  L),  pct(mem) },
        { "TEMP", temp / C.temp_max, level_color(temp, TL), string.format("%d°", math.floor(temp + 0.5)) },
        { "ROOT", root / 100,       level_color(root, L),  pct(root) },
        { "HOME", home / 100,       level_color(home, L),  pct(home) },
    }

    local step = TWO_PI / #meters
    for i, m in ipairs(meters) do
        draw_meter(cr, -PI/2 + (i-1)*step, step - rad(C.meter_gap), m[2], m[3], m[1], m[4])
    end
end

-- ── MAIN DRAW ─────────────────────────────────────────────────────────────
local meters_on = C.show_meters   -- runtime state; the mouse hook flips it
local _size_logged = false

function conky_draw_solar_dial3()
    if conky_window==nil then return end
    if not _size_logged and conky_window.width > 0 then
        print(string.format("[%s] window: %d x %d",
            conky_config:match("([^/]+)$"), conky_window.width, conky_window.height))
        _size_logged = true
    end
    local cs, owns = surface.get()
    if cs == nil then return end
    local cr=cairo_create(cs)

    -- conky can hand back a window larger than minimum_width (270 → 280),
    -- so centre on what we actually got rather than the configured size.
    if conky_window.width > 0 then
        C.cx, C.cy = conky_window.width/2, conky_window.height/2
    end
    local cx,cy = C.cx,C.cy
    local tz    = tz_offset()
    local now   = os.time(); local tm=os.date("*t",now)
    local y,mo,d  = tm.year,tm.month,tm.day
    local hh,mi,ss = tm.hour,tm.min,tm.sec
    local cur_h   = hh+mi/60.0+ss/3600.0
    local cur_alt = sun_alt_at(y,mo,d,cur_h,tz)
    local ev      = get_events(y,mo,d,tz)

    -- ── 1. Sky gradient (full disc) ───────────────────────────────────────
    draw_sky(cr,y,mo,d,tz)

    -- ── 1a. Dark annular bezel (dark theme) ───────────────────────────────
    if T.annular_bezel then
        local bz = cairo_pattern_create_radial(cx,cy, C.dial_r, cx,cy, C.face_r)
        cairo_pattern_add_color_stop_rgba(bz, 0.0, 0.10,0.10,0.10, 0.0)
        cairo_pattern_add_color_stop_rgba(bz, 0.3, 0.10,0.10,0.10, 0.7)
        cairo_pattern_add_color_stop_rgba(bz, 1.0, 0.06,0.06,0.06, 0.92)
        cairo_arc(cr,cx,cy,C.face_r,0,TWO_PI)
        cairo_set_source(cr,bz); cairo_fill(cr); cairo_pattern_destroy(bz)
    end

    -- ── 1b. Outer decorative ring ─────────────────────────────────────────
    cairo_new_path(cr)
    cairo_arc(cr,cx,cy,C.ring_r+3,0,TWO_PI)
    local rr=T.ring_rgba
    cairo_set_source_rgba(cr,rr[1],rr[2],rr[3],rr[4])
    cairo_set_line_width(cr,1.5)
    cairo_stroke(cr)

    -- ── 2. Hour tick marks ────────────────────────────────────────────────
    for h=0,23 do
        local a=h2a(h)
        local major=(h%6==0); local med=(h%2==0)
        local t_in = C.ring_r-(major and 8 or med and 5 or 3)
        cairo_move_to(cr, cx+t_in    *math.cos(a), cy+t_in    *math.sin(a))
        cairo_line_to(cr, cx+C.ring_r*math.cos(a), cy+C.ring_r*math.sin(a))
        cairo_set_source_rgba(cr,1,1,1, major and 1.0 or med and 0.60 or 0.28)
        cairo_set_line_width(cr, major and 1.5 or 0.8)
        cairo_stroke(cr)
    end
    -- half-hour minor ticks
    for i=0,23 do
        local a=h2a(i+0.5)
        cairo_move_to(cr, cx+(C.ring_r-2)*math.cos(a), cy+(C.ring_r-2)*math.sin(a))
        cairo_line_to(cr, cx+C.ring_r    *math.cos(a), cy+C.ring_r    *math.sin(a))
        cairo_set_source_rgba(cr,1,1,1,0.18); cairo_set_line_width(cr,0.6); cairo_stroke(cr)
    end

    -- ── 3. Hour labels (even hours in bezel band) ─────────────────────────
    local lr = 79
    for h=0,22,2 do
        local a=h2a(h)
        local lbl = (h==0) and "24" or string.format("%02d",h)
        local bold = (h==0 or h==6 or h==12 or h==18) and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL
        textc(cr,lbl, cx+lr*math.cos(a), cy+lr*math.sin(a), C.font,12,bold, 1,1,1, (h%6==0) and 0.95 or 0.75)
    end

    -- ── 4. Dim full-orbit guide ring ─────────────────────────────────────
    cairo_new_path(cr)
    cairo_arc(cr,cx,cy,C.arc_r,0,TWO_PI)
    cairo_set_source_rgba(cr,1,1,1,0.08)
    cairo_set_line_width(cr,0.8)
    cairo_stroke(cr)

    -- ── 5. Bright daytime arc (sunrise → sunset, through noon) ───────────
    if ev.sunrise and ev.sunset then
        local a_sr=h2a(ev.sunrise); local a_ss=h2a(ev.sunset)
        cairo_arc(cr,cx,cy,C.arc_r, a_sr, a_ss)
        cairo_set_source_rgba(cr,1,1,1,0.82)
        cairo_set_line_width(cr,1.5)
        cairo_stroke(cr)
    elseif ev.noon_alt and ev.noon_alt>0 then
        cairo_arc(cr,cx,cy,C.arc_r,0,TWO_PI)
        cairo_set_source_rgba(cr,1,1,1,0.82); cairo_set_line_width(cr,1.5); cairo_stroke(cr)
    end

    -- ── 6. Event dots (sunrise, solar noon, sunset) ───────────────────────
    local function evdot(lh,dc,lbl,lc)
        local a=h2a(lh); local ex=cx+C.arc_r*math.cos(a); local ey=cy+C.arc_r*math.sin(a)
        cairo_arc(cr,ex,ey,3.5,0,TWO_PI)
        cairo_set_source_rgba(cr,dc[1],dc[2],dc[3],0.95); cairo_fill(cr)
        if lbl then
            textc(cr,lbl, ex, ey+10, C.font,9,CAIRO_FONT_WEIGHT_NORMAL, lc[1],lc[2],lc[3],0.85)
        end
    end
    if ev.sunrise then evdot(ev.sunrise,{1.0,0.72,0.22},"↑"..fmth(ev.sunrise),{1.0,0.80,0.35}) end
    if ev.sunset  then evdot(ev.sunset, {0.95,0.45,0.15},"↓"..fmth(ev.sunset), {1.0,0.62,0.28}) end
    if ev.noon    then
        local a=h2a(ev.noon); local nx=cx+C.arc_r*math.cos(a); local ny=cy+C.arc_r*math.sin(a)
        cairo_arc(cr,nx,ny,2.5,0,TWO_PI); cairo_set_source_rgba(cr,1,1,0.5,0.75); cairo_fill(cr)
    end

    -- ── 7. Sun dot ────────────────────────────────────────────────────────
    local sa=h2a(cur_h)
    local sx=cx+C.arc_r*math.cos(sa); local sy=cy+C.arc_r*math.sin(sa)
    cairo_new_path(cr)
    cairo_move_to(cr, cx, cy)
    cairo_line_to(cr, cx+(C.arc_r+6+5)*math.cos(sa), cy+(C.arc_r+6+5)*math.sin(sa))
    cairo_set_source_rgba(cr,1,1,1,0.55); cairo_set_line_width(cr,0.8); cairo_stroke(cr)
    local dr,dg,db
    if cur_alt>0 then dr,dg,db=1.00,0.92,0.35
    elseif cur_alt>-8 then
        local t2=(cur_alt+8)/8; dr=lerp(0.40,1.00,t2); dg=lerp(0.50,0.92,t2); db=lerp(0.75,0.35,t2)
    else dr,dg,db=0.40,0.50,0.75 end
    for i=11,1,-1 do
        cairo_arc(cr,sx,sy,i,0,TWO_PI)
        cairo_set_source_rgba(cr,dr,dg,db, 0.030*(12-i)/11); cairo_fill(cr)
    end
    local dot_r=7; local split_alt=2
    if cur_alt>=split_alt then
        cairo_arc(cr,sx,sy,dot_r,0,TWO_PI); cairo_set_source_rgba(cr,1.00,0.92,0.35,1.0); cairo_fill(cr)
    elseif cur_alt<=-split_alt then
        cairo_arc(cr,sx,sy,dot_r,0,TWO_PI); cairo_set_source_rgba(cr,0.40,0.50,0.75,1.0); cairo_fill(cr)
    else
        local hr=clamp(cur_alt/split_alt,-1,1)*dot_r
        local rot=(cur_h<(ev.noon or 12)) and (sa+math.pi) or sa
        cairo_save(cr); cairo_translate(cr,sx,sy); cairo_rotate(cr,rot)
        cairo_save(cr); cairo_rectangle(cr,-dot_r-1,-dot_r-1,dot_r*2+2,hr+dot_r+1); cairo_clip(cr)
        cairo_arc(cr,0,0,dot_r,0,TWO_PI); cairo_set_source_rgba(cr,1.00,0.92,0.35,1.0); cairo_fill(cr); cairo_restore(cr)
        cairo_save(cr); cairo_rectangle(cr,-dot_r-1,hr,dot_r*2+2,dot_r+1-hr); cairo_clip(cr)
        cairo_arc(cr,0,0,dot_r,0,TWO_PI); cairo_set_source_rgba(cr,0.40,0.50,0.75,1.0); cairo_fill(cr); cairo_restore(cr)
        cairo_restore(cr)
    end
    cairo_arc(cr,sx,sy,dot_r,0,TWO_PI); cairo_set_source_rgba(cr,0,0,0,0.40); cairo_set_line_width(cr,1.8); cairo_stroke(cr)
    if cur_alt>0 then cairo_arc(cr,sx-2,sy-2,2,0,TWO_PI); cairo_set_source_rgba(cr,1,1,1,0.50); cairo_fill(cr) end

    -- ── 8. Central frosted clock disc ─────────────────────────────────────
    local cg=cairo_pattern_create_radial(cx,cy,0, cx,cy,C.clock_r)
    cairo_pattern_add_color_stop_rgba(cg,0.0, 1,1,1,0.22)
    cairo_pattern_add_color_stop_rgba(cg,0.7, 1,1,1,0.16)
    cairo_pattern_add_color_stop_rgba(cg,1.0, 1,1,1,0.06)
    cairo_arc(cr,cx,cy,C.clock_r,0,TWO_PI); cairo_set_source(cr,cg); cairo_fill(cr)
    cairo_pattern_destroy(cg)
    cairo_arc(cr,cx,cy,C.clock_r,0,TWO_PI)
    cairo_set_source_rgba(cr,1,1,1,0.28); cairo_set_line_width(cr,0.6); cairo_stroke(cr)

    -- ── 9. Time ───────────────────────────────────────────────────────────
    textc(cr, string.format("%02d:%02d",hh,mi), cx,cy-8, C.font,23,CAIRO_FONT_WEIGHT_BOLD, 1,1,1,0.97)

    -- ── 10. Date ──────────────────────────────────────────────────────────
    textc(cr, os.date("%a %b %d",now), cx,cy+9, C.font,8,CAIRO_FONT_WEIGHT_NORMAL, 1,1,1,0.70)

    -- ── 11. Sun status ────────────────────────────────────────────────────
    local stat
    if    cur_alt> 15 then stat=string.format("%.0f° above horizon",cur_alt)
    elseif cur_alt> 6 then stat=string.format("%.1f° above horizon",cur_alt)
    elseif cur_alt> 0 then stat="Golden hour"
    elseif cur_alt>-6 then stat="Civil twilight"
    elseif cur_alt>-12 then stat="Nautical twilight"
    elseif cur_alt>-18 then stat="Astronomical twilight"
    else                    stat=string.format("%.0f° below horizon",-cur_alt)
    end
    local sr2,sg2,sb2 = alt_to_sector_color(cur_alt)
    textc(cr,stat, cx,cy+20, C.font,7,CAIRO_FONT_WEIGHT_NORMAL,
        math.min(1, sr2+0.15), math.min(1, sg2+0.15), math.min(1, sb2+0.25), 0.90)

    -- ── 12. Centre pivot ──────────────────────────────────────────────────
    cairo_arc(cr,cx,cy,2.0,0,TWO_PI); cairo_set_source_rgba(cr,1,1,1,0.55); cairo_fill(cr)

    -- ── 13. System meter ring ─────────────────────────────────────────────
    if meters_on then draw_meters(cr) end

    cairo_destroy(cr)
    surface.put(cs, owns)
end

-- Shift+left-click anywhere on the widget: show/hide the meter ring.
-- Ctrl+clicks still go to window.lua (save position / close).
function conky_mouse_hook(event)
    if event.type == "button_down" and event.button == "left"
       and event.mods and event.mods.shift then
        meters_on = not meters_on
        return true
    end
    return window.handle_mouse(event)
end

if conky then
  conky.config = {
-- ─────────────────────────────────────────────────────────────────────────────
--  Solar Dial 4  –  200 px dial + system meter ring, 270 px window
-- ─────────────────────────────────────────────────────────────────────────────

-- Window
    background            = false,
    own_window            = true,
    own_window_type       = 'normal',
    own_window_transparent = true,
    own_window_argb_visual = true,
    own_window_argb_value  = 0,
    own_window_class      = 'Conky',
    own_window_title      = 'sdr3',
    own_window_hints      = 'undecorated,sticky,skip_taskbar,skip_pager,below',

-- Size & position
    alignment             = 'bottom_middle',
    gap_x                 =  0,
    gap_y                 =  95,    -- 130 - 35: keeps the dial where solar_dial2 had it
    minimum_width         = 270,
    minimum_height        = 270,
    maximum_width         = 270,

-- Rendering
    double_buffer         = true,
    update_interval       = 2,     -- meters need live readings; the dial itself is cheap

-- Text / font
    use_xft               = true,
    font                  = 'DejaVu Sans:size=8',
    override_utf8_locale  = true,
    out_to_console        = false,
    out_to_stderr         = false,
    extra_newline         = false,

-- Misc
    draw_shades           = false,
    draw_borders          = false,
    draw_graph_borders    = false,
    draw_outline          = false,
    stippled_borders      = 0,
    uppercase             = false,
    use_spacer            = 'none',

-- Lua
    lua_load              = './solar_dial3.lua',
    lua_draw_hook_post    = 'draw_solar_dial3',
    lua_mouse_hook        = 'mouse_hook',
  }

  conky.text = [[]]
end
