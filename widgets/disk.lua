-- disk.lua - Disk I/O tick graph with Cairo column header (Rubik font)
-- v1 2026-07-04 @rew62

require 'cairo'

local M = {}

local HIST_N  = 71
local rd_hist = {}
local wr_hist = {}
local head    = 1

for i = 1, HIST_N do rd_hist[i] = 0; wr_hist[i] = 0 end

local C_RD   = { 0.40, 0.60, 0.92 }
local C_WR   = { 0.62, 0.82, 1.00 }
local C_LINE = { 0.38, 0.56, 0.88 }

-- header colors (ticker3-style)
local C_HEAD  = { 0x2D/255, 0x9E/255, 0xEA/255 }
local C_WHITE = { 0xe8/255, 0xe8/255, 0xe8/255 }

-- header layout: two side-by-side label+value pairs
local HDR_M  = 4   -- left pair label left edge
local HDR_LV = 72  -- left pair value right edge
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
    local fs_perc = get_stat("${fs_used_perc /}")
    local fs_size = get_stat("${fs_size /}")
    local fs_used = get_stat("${fs_used /}")
    local fs_free = get_stat("${fs_free /}")

    cairo_set_font_size(cr, 10)

    -- row 1: Disk <perc%>   Used <used>
    local y = HDR_R1
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(cr, C_HEAD)
    dl(cr, HDR_M,  y, "Disk")
    dl(cr, HDR_RL, y, "Used")
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(cr, C_WHITE)
    dr(cr, HDR_LV, y, fs_perc .. "%")
    dr(cr, xr,     y, fs_used)

    -- row 2: Total <size>   Free <free>
    y = HDR_R2
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    sc(cr, C_HEAD)
    dl(cr, HDR_M,  y, "Total")
    dl(cr, HDR_RL, y, "Free")
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    sc(cr, C_WHITE)
    dr(cr, HDR_LV, y, fs_size)
    dr(cr, xr,     y, fs_free)
end

local function parse_kbs(s)
    local n, u = tostring(s or ""):match("([%d%.]+)%s*([%a]*)")
    n = tonumber(n) or 0
    u = (u or ""):sub(1,1):upper()
    if     u == "G" then return n * 1048576
    elseif u == "M" then return n * 1024
    elseif u == "K" then return n
    else                  return n / 1024
    end
end

local function fmt(kbs)
    if     kbs >= 1024 then return string.format("%.1f M", kbs / 1024)
    elseif kbs >= 1    then return string.format("%.1f k", kbs)
    else                    return string.format("%d b",   math.floor(kbs * 1024))
    end
end

local function get(arr, age)
    return arr[((head - 2 - age) % HIST_N + HIST_N) % HIST_N + 1]
end

function M.update(dev)
    local rs = conky_parse("${diskio_read "  .. dev .. "}")
    local ws = conky_parse("${diskio_write " .. dev .. "}")
    rd_hist[head] = parse_kbs(rs)
    wr_hist[head] = parse_kbs(ws)
    head = (head % HIST_N) + 1
end

function M.draw(cr, w, h)
    local top_off = (type(DISK_TOP_OFFSET) == "number") and DISK_TOP_OFFSET or 0
    local bot_off = (type(DISK_BOT_OFFSET) == "number") and DISK_BOT_OFFSET or 0
    local eff_h   = h - top_off - bot_off
    local off_y   = top_off

    draw_header(cr, w)

    local pad_x  = 4
    local cx     = math.floor(w / 2)
    local cur_rd = get(rd_hist, 0)
    local cur_wr = get(wr_hist, 0)

    local fe = cairo_font_extents_t:create(); tolua.takeownership(fe)
    local te = cairo_text_extents_t:create(); tolua.takeownership(te)
    cairo_select_font_face(cr, "Rubik", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 9)
    cairo_font_extents(cr, fe)

    local text_y

    if DISPLAY_GRAPH ~= false then
        local line_top = off_y + math.floor(eff_h * 0.36)
        local line_bot = off_y + math.floor(eff_h * 0.64)
        text_y = math.floor((line_top + line_bot) / 2) + (fe.ascent - fe.descent) / 2

        local up_zone  = line_top - off_y - 4
        local dn_zone  = off_y + eff_h - line_bot - 1

        local tick_w   = 1
        local tick_sp  = 1
        local stride   = tick_w + tick_sp

        local inner_w  = w - pad_x * 2
        local n        = math.min(HIST_N, math.floor(inner_w / stride))

        -- scale floor 100 MB/s: bursts below this never claim full height, so
        -- a modest 10-20 MB write on an idle disk reads as a mid bar, not max
        local peak_rd, peak_wr = 102400, 102400
        for i = 1, HIST_N do
            if rd_hist[i] > peak_rd then peak_rd = rd_hist[i] end
            if wr_hist[i] > peak_wr then peak_wr = wr_hist[i] end
        end

        for i = 0, n - 1 do
            local age = n - 1 - i
            local x   = w - pad_x - tick_w - age * stride
            local v   = get(rd_hist, age)
            if v > 0 then
                local th = math.max(2, math.floor((v / peak_rd) ^ (1/3) * up_zone))
                cairo_set_source_rgba(cr, C_RD[1], C_RD[2], C_RD[3], 0.88)
                cairo_rectangle(cr, x, line_top - th, tick_w, th)
                cairo_fill(cr)
            end
        end

        for i = 0, n - 1 do
            local age = n - 1 - i
            local x   = w - pad_x - tick_w - age * stride
            local v   = get(wr_hist, age)
            if v > 0 then
                local th = math.max(2, math.floor((v / peak_wr) ^ (1/3) * dn_zone))
                cairo_set_source_rgba(cr, C_WR[1], C_WR[2], C_WR[3], 0.88)
                cairo_rectangle(cr, x, line_bot, tick_w, th)
                cairo_fill(cr)
            end
        end

        cairo_set_line_width(cr, 2)
        cairo_set_source_rgba(cr, C_LINE[1], C_LINE[2], C_LINE[3], 0.65)
        cairo_move_to(cr, pad_x, line_top); cairo_line_to(cr, w - pad_x, line_top); cairo_stroke(cr)
        cairo_move_to(cr, pad_x, line_bot); cairo_line_to(cr, w - pad_x, line_bot); cairo_stroke(cr)

        cairo_set_source_rgba(cr, C_LINE[1], C_LINE[2], C_LINE[3], 0.30)
        cairo_set_line_width(cr, 1)
        cairo_move_to(cr, cx, line_top + 3); cairo_line_to(cr, cx, line_bot - 3); cairo_stroke(cr)
    else
        text_y = off_y + math.floor(eff_h / 2) + (fe.ascent - fe.descent) / 2
    end

    local rd_val = fmt(cur_rd)
    local rd_lbl = " - RD"
    cairo_text_extents(cr, rd_val .. rd_lbl, te)
    cairo_move_to(cr, (cx - te.width) / 2 - te.x_bearing, text_y)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    cairo_show_text(cr, rd_val)
    cairo_set_source_rgba(cr, C_RD[1], C_RD[2], C_RD[3], 0.95)
    cairo_show_text(cr, rd_lbl)

    local wr_lbl = "WR - "
    local wr_val = fmt(cur_wr)
    cairo_text_extents(cr, wr_lbl .. wr_val, te)
    cairo_move_to(cr, cx + (cx - te.width) / 2 - te.x_bearing, text_y)
    cairo_set_source_rgba(cr, C_WR[1], C_WR[2], C_WR[3], 0.95)
    cairo_show_text(cr, wr_lbl)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    cairo_show_text(cr, wr_val)

    draw_dividers(cr, w, h)
end

return M
