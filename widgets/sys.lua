-- sys.lua - CPU/load tick graph with Cairo column header (Rubik font)
-- v1 2026-07-04 @rew62

require 'cairo'
pcall(require, 'cairo_xlib')  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local M = {}

local HIST_N    = 71
local cpu_hist  = {}
local load_hist = {}
local head      = 1
-- M.cpu_raw: last ${cpu cpu0} string, cached by M.update() so draw_header()
-- (and the nsd/nsd2 combo views) don't re-parse it the same tick

-- battery/thermal presence is static hardware state: probe sysfs once at
-- load instead of io.open()ing every frame
local function sysfs_exists(p)
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end
local HAS_BAT = sysfs_exists("/sys/class/power_supply/BAT0/uevent")
local HAS_TZ  = sysfs_exists("/sys/class/thermal/thermal_zone0/temp")

for i = 1, HIST_N do cpu_hist[i] = 0; load_hist[i] = 0 end

local C_CPU1 = { 0.40, 0.60, 0.92 }
local C_CPU2 = { 0.62, 0.82, 1.00 }
local C_LINE = { 0.38, 0.56, 0.88 }

local TEMP_LO = 30
local TEMP_HI = 95

local function lerp(a, b, t) return a + (b - a) * t end

local function temp_color(pct)
    if pct < 0.5 then
        local t = pct / 0.5
        return lerp(0.30, 0.92, t), lerp(0.72, 0.76, t), lerp(1.00, 0.22, t)
    else
        local t = (pct - 0.5) / 0.5
        return lerp(0.92, 1.00, t), lerp(0.76, 0.18, t), lerp(0.22, 0.05, t)
    end
end

-- header colors (ticker3-style)
local C_HEAD  = { 0x2D/255, 0x9E/255, 0xEA/255 }
local C_WHITE = { 0xe8/255, 0xe8/255, 0xe8/255 }

-- header layout: two side-by-side label+value pairs
local HDR_M  = 4   -- left pair label left edge
local HDR_LV = 65  -- left pair value right edge
local HDR_RL = 90  -- right pair label left edge
local HDR_R1 = 13  -- row 1 baseline
local HDR_R2 = 26  -- row 2 baseline

local function sc(cr, c, a)
    cairo_set_source_rgba(cr, c[1], c[2], c[3], a or 1.0)
end

local function dl(cr, x, y, s)
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, s)
end

local function dr(cr, x, y, s)
    local e = cairo_text_extents_t:create()
    tolua.takeownership(e)
    cairo_text_extents(cr, s, e)
    cairo_move_to(cr, x - e.x_advance, y)
    cairo_show_text(cr, s)
end

local function get_stat(var)
    local v = conky_parse(var)
    return (v and v ~= "") and v or "--"
end

local function draw_header(cr, w)
    local xr      = w - HDR_M
    local cpu_pct = ((M.cpu_raw and M.cpu_raw ~= "") and M.cpu_raw or "--") .. "%"
    local mem_pct = get_stat("${memperc}") .. "%"
    local uptime  = get_stat("${uptime_short}")

    local right2_lbl, right2_val, right2_temp
    if HAS_BAT then
        right2_lbl = "PWR"
        right2_val = get_stat("${battery_percent BAT0}") .. "%"
    else
        right2_lbl = "TEMP"
        if HAS_TZ then
            local raw   = get_stat("${acpitemp}")
            right2_val  = raw .. "\xc2\xb0"
            right2_temp = tonumber(raw)
        else
            -- no ACPI thermal zone (VMs): ${acpitemp} logs a conky error
            -- every update; nil right2_temp keeps the neutral color below
            right2_val = "--\xc2\xb0"
        end
    end

    cairo_set_font_size(cr, 10)

    -- row 1: CPU <cpu%>   RAM <mem%>
    local y = HDR_R1
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(cr, C_HEAD)
    dl(cr, HDR_M,  y, "CPU")
    dl(cr, HDR_RL, y, "RAM")
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(cr, C_WHITE)
    dr(cr, HDR_LV, y, cpu_pct)
    dr(cr, xr,     y, mem_pct)

    -- row 2: HDD <size>   PWR/TEMP <val>
    y = HDR_R2
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(cr, C_HEAD)
    dl(cr, HDR_M,  y, "UP")
    dl(cr, HDR_RL, y, right2_lbl)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(cr, C_WHITE)
    dr(cr, HDR_LV, y, uptime)
    if right2_temp then
        local pct = math.max(0, math.min(1, (right2_temp - TEMP_LO) / (TEMP_HI - TEMP_LO)))
        local vr, vg, vb = temp_color(pct)
        cairo_set_source_rgba(cr, vr, vg, vb, 1.0)
    end
    dr(cr, xr,     y, right2_val)
end

local function get(arr, age)
    return arr[((head - 2 - age) % HIST_N + HIST_N) % HIST_N + 1]
end

function M.update()
    M.cpu_raw  = conky_parse("${cpu cpu0}")
    local cpu  = tonumber(M.cpu_raw) or 0
    local load = tonumber(conky_parse("${loadavg 1}")) or 0
    cpu_hist[head]  = cpu
    load_hist[head] = load
    head = (head % HIST_N) + 1
end

function M.draw(cr, w, h)
    local top_off = (type(SYS_TOP_OFFSET) == "number") and SYS_TOP_OFFSET or 0
    local bot_off = (type(SYS_BOT_OFFSET) == "number") and SYS_BOT_OFFSET or 0
    local eff_h   = h - top_off - bot_off
    local off_y   = top_off

    draw_header(cr, w)

    if DISPLAY_GRAPH ~= false then
        local pad_x    = 4
        local line_top = off_y + math.floor(eff_h * 0.36)
        local line_bot = off_y + math.floor(eff_h * 0.64)
        local cx       = math.floor(w / 2)

        local up_zone  = line_top - off_y - 4
        local dn_zone  = off_y + eff_h - line_bot - 1

        local tick_w   = 1
        local tick_sp  = 1
        local stride   = tick_w + tick_sp

        local inner_w  = w - pad_x * 2
        local n        = math.min(HIST_N, math.floor(inner_w / stride))

        local peak_cpu, peak_load = 40, 8
        for i = 1, HIST_N do
            if cpu_hist[i]  > peak_cpu  then peak_cpu  = cpu_hist[i]  end
            if load_hist[i] > peak_load then peak_load = load_hist[i] end
        end

        for i = 0, n - 1 do
            local age = n - 1 - i
            local x   = w - pad_x - tick_w - age * stride
            local v   = get(cpu_hist, age)
            if v > 0 then
                local th = math.max(2, math.floor(v / peak_cpu * up_zone))
                cairo_set_source_rgba(cr, C_CPU1[1], C_CPU1[2], C_CPU1[3], 0.88)
                cairo_rectangle(cr, x, line_top - th, tick_w, th)
                cairo_fill(cr)
            end
        end

        for i = 0, n - 1 do
            local age = n - 1 - i
            local x   = w - pad_x - tick_w - age * stride
            local v   = get(load_hist, age)
            if v > 0 then
                local th = math.max(2, math.floor(v / peak_load * dn_zone))
                cairo_set_source_rgba(cr, C_CPU2[1], C_CPU2[2], C_CPU2[3], 0.88)
                cairo_rectangle(cr, x, line_bot, tick_w, th)
                cairo_fill(cr)
            end
        end

        cairo_set_line_width(cr, 2)
        cairo_set_source_rgba(cr, C_LINE[1], C_LINE[2], C_LINE[3], 0.65)
        cairo_move_to(cr, pad_x, line_top); cairo_line_to(cr, w - pad_x, line_top); cairo_stroke(cr)
        cairo_move_to(cr, pad_x, line_bot); cairo_line_to(cr, w - pad_x, line_bot); cairo_stroke(cr)

        local cur_cpu  = get(cpu_hist, 0)
        local cur_load = get(load_hist, 0)

        local fe = cairo_font_extents_t:create(); tolua.takeownership(fe)
        local te = cairo_text_extents_t:create(); tolua.takeownership(te)
        cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 9)
        cairo_font_extents(cr, fe)
        local text_y = math.floor((line_top + line_bot) / 2) + (fe.ascent - fe.descent) / 2

        cairo_set_source_rgba(cr, C_LINE[1], C_LINE[2], C_LINE[3], 0.30)
        cairo_set_line_width(cr, 1)
        cairo_move_to(cr, cx, line_top + 3); cairo_line_to(cr, cx, line_bot - 3); cairo_stroke(cr)

        local cpu_val = string.format("%d%%", cur_cpu)
        local cpu_lbl = " - CPU"
        cairo_text_extents(cr, cpu_val .. cpu_lbl, te)
        cairo_move_to(cr, (cx - te.width) / 2 - te.x_bearing, text_y)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
        cairo_show_text(cr, cpu_val)
        cairo_set_source_rgba(cr, C_CPU1[1], C_CPU1[2], C_CPU1[3], 0.95)
        cairo_show_text(cr, cpu_lbl)

        local load_lbl = "LOAD - "
        local load_val = string.format("%.2f", cur_load)
        cairo_text_extents(cr, load_lbl .. load_val, te)
        cairo_move_to(cr, cx + (cx - te.width) / 2 - te.x_bearing, text_y)
        cairo_set_source_rgba(cr, C_CPU2[1], C_CPU2[2], C_CPU2[3], 0.95)
        cairo_show_text(cr, load_lbl)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
        cairo_show_text(cr, load_val)
    end -- DISPLAY_GRAPH

    draw_dividers(cr, w, h)
end

return M
