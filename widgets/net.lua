-- net.lua - Network graph with NET_TOP_OFFSET / NET_BOT_OFFSET support.
-- Variant of net.lua; graph is confined to [off_y, off_y+eff_h] so conky
-- text can render above and below without being overdrawn.
-- v1 2026-07-04 @rew62

require 'cairo'
pcall(require, 'cairo_xlib')  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local M = {}

local HIST_N  = 142  -- (w-8)/1: 128→120, 150→142, 200→192 (stride=1, no gap)
local up_hist = {}
local dn_hist = {}
local head    = 1

for i = 1, HIST_N do up_hist[i] = 0; dn_hist[i] = 0 end

local C_UP   = { 0.40, 0.60, 0.92 }
local C_DN   = { 0.62, 0.82, 1.00 }
local C_LINE = { 0.38, 0.56, 0.88 }

local function fmt(kbs)
    if     kbs >= 1024 then return string.format("%.1f M", kbs / 1024)
    elseif kbs >= 1    then return string.format("%.1f k", kbs)
    else                    return string.format("%d b",   math.floor(kbs * 1024))
    end
end

local function get(arr, age)
    return arr[((head - 2 - age) % HIST_N + HIST_N) % HIST_N + 1]
end

function M.update(iface)
    local up = tonumber(conky_parse("${upspeedf "   .. iface .. "}")) or 0
    local dn = tonumber(conky_parse("${downspeedf " .. iface .. "}")) or 0
    -- latest samples (KiB/s, pre-floor) for readers that want the current
    -- value without re-parsing the same variables this tick (nsd/nsd2 combo)
    M.last_up, M.last_dn = up, dn
    -- noise floor: ignore background chatter (ARP/mDNS/etc) under 1 KiB/s
    if up < 1 then up = 0 end
    if dn < 1 then dn = 0 end
    up_hist[head] = up
    dn_hist[head] = dn
    head = (head % HIST_N) + 1
end

function M.draw(cr, w, h)
    local top_off = (type(NET_TOP_OFFSET) == "number") and NET_TOP_OFFSET or 0
    local bot_off = (type(NET_BOT_OFFSET) == "number") and NET_BOT_OFFSET or 0
    local eff_h   = h - top_off - bot_off
    local off_y   = top_off

    local pad_x    = 4
    local line_top = off_y + math.floor(eff_h * 0.36)
    local line_bot = off_y + math.floor(eff_h * 0.64)
    local cx       = math.floor(w / 2)

    local up_zone  = line_top - off_y - 4
    local dn_zone  = off_y + eff_h - line_bot - 4

    local tick_w   = 1
    local tick_sp  = 0
    local stride   = tick_w + tick_sp

    local inner_w  = w - pad_x * 2
    local n        = math.min(HIST_N, math.floor(inner_w / stride))

    local peak_up, peak_dn = 8, 8
    for i = 1, HIST_N do
        if up_hist[i] > peak_up then peak_up = up_hist[i] end
        if dn_hist[i] > peak_dn then peak_dn = dn_hist[i] end
    end

    for i = 0, n - 1 do
        local age = n - 1 - i
        local x   = w - pad_x - tick_w - (n - 1 - i) * stride

        local uv = get(up_hist, age)
        if uv > 0 then
            local uh = math.max(2, math.floor(uv / peak_up * up_zone))
            cairo_set_source_rgba(cr, C_UP[1], C_UP[2], C_UP[3], 0.88)
            cairo_rectangle(cr, x, line_top - uh, tick_w, uh)
            cairo_fill(cr)
        end

        local dv = get(dn_hist, age)
        if dv > 0 then
            local dh = math.max(2, math.floor(dv / peak_dn * dn_zone))
            cairo_set_source_rgba(cr, C_DN[1], C_DN[2], C_DN[3], 0.88)
            cairo_rectangle(cr, x, line_bot, tick_w, dh)
            cairo_fill(cr)
        end
    end

    cairo_set_line_width(cr, 1)
    cairo_set_source_rgba(cr, C_LINE[1], C_LINE[2], C_LINE[3], 0.65)
    cairo_move_to(cr, pad_x, line_top); cairo_line_to(cr, w - pad_x, line_top); cairo_stroke(cr)
    cairo_move_to(cr, pad_x, line_bot); cairo_line_to(cr, w - pad_x, line_bot); cairo_stroke(cr)

    local cur_up = get(up_hist, 0)
    local cur_dn = get(dn_hist, 0)

    local fe = cairo_font_extents_t:create(); tolua.takeownership(fe)
    local te = cairo_text_extents_t:create(); tolua.takeownership(te)

    cairo_select_font_face(cr, "Roboto", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 9)
    cairo_font_extents(cr, fe)
    local text_y = math.floor((line_top + line_bot) / 2) + (fe.ascent - fe.descent) / 2

    cairo_set_source_rgba(cr, C_LINE[1], C_LINE[2], C_LINE[3], 0.30)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, cx, line_top + 3); cairo_line_to(cr, cx, line_bot - 3); cairo_stroke(cr)

    local up_val = fmt(cur_up)
    local up_lbl = " - UP"
    cairo_text_extents(cr, up_val .. up_lbl, te)
    cairo_move_to(cr, (cx - te.width) / 2 - te.x_bearing, text_y)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    cairo_show_text(cr, up_val)
    cairo_set_source_rgba(cr, C_UP[1], C_UP[2], C_UP[3], 0.95)
    cairo_show_text(cr, up_lbl)

    local dn_val = fmt(cur_dn)
    local dn_lbl = "DOWN - "
    cairo_text_extents(cr, dn_lbl .. dn_val, te)
    cairo_move_to(cr, cx + (cx - te.width) / 2 - te.x_bearing, text_y)
    cairo_set_source_rgba(cr, C_DN[1], C_DN[2], C_DN[3], 0.95)
    cairo_show_text(cr, dn_lbl)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    cairo_show_text(cr, dn_val)

    draw_dividers(cr, w, h)
end

return M
