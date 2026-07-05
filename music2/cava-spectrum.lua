--[[ BARGRAPH WIDGET
    Originally written by v2.0 by wlourf (12.07.2010)
    this widget draws a bargraph with differe,ts effects
    http://u-scripts.blogspot.com/2010/07/bargraph-widget.html
    Rewritten by Koentje and Bleys for use with cava as Spectrum Equalizer in conky (03.11.2023)
    Edited 2026-07-04 by @rew62 to add mouse click events, print config name in lua

Parameters are :
3 parameters are mandatory
name    - the name of the conky variable to display, for example for {$cpu cpu0}, just write name="cpu"
arg     - the argument of the above variable, for example for {$cpu cpu0}, just write arg="cpu0"
          arg can be a numericla value if name=""
max     - the maximum value the above variable can reach, for example for {$cpu cpu0}, just write  max=100

Optional parameters:
bars        - How many bars are shown
barspaces   - Space between bars, default=2 pixels
x,y         - coordinates of the starting point of the first bar, default = middle of the conky window
cap         - end of cap line, possibles values are r,b,s (for round, butt, square), default="b"
              http://www.cairographics.org/samples/set_line_cap/
angle       - angle of rotation of the bar in degress, default = 0 (i.e. a vertical bar)
              set to 90 for an horizontal bar
skew_x      - skew bar around x axis, dfaut = 0
skew_y      - skew bar around y axis, dfaut = 0
blocks      - number of blocks to display for a bar (values >0) , default= 10
height      - height of a block, default=10 pixels
width       - width of a block, default=20 pixels
blockspaces - space between 2 blocks, default=2 pixels
angle_bar   - this angle is used to draw a bar on a circular way (ok, this is no more a bar !) default=0
radius      - for cicular bars, internal radius, default=0
              with radius, parameter width has no more effect.

Colours below are defined into braces {colour in hexadecimal, alpha}
fg_colour   - colour of a block ON, default= {0x00FF00,1}
bg_colour   - colour of a block OFF, défaut = {width=500x00FF00,0.5}
alarm       - threshold, values after this threshold will use alarm_colour colour , default=max
alarm_colour- colour of a block greater than alarm, default=fg_colour
smooth      - (true or false), create a gradient from fg_colour to bg_colour, default=false
mid_colour  - colours to add to gradient, with this syntax {position into the gradient (0 to1), colour hexa, alpha}
              for example, this table {{0.25,0xff0000,1},{0.5,0x00ff00,1},{0.75,0x0000ff,1}} will add
              3 colurs to gradient created by fg_colour and alarm_colour, default=no mid_colour
fg_led      - middle colour of a block ON, default = fg_colour
bg_led      - middle colour of a block OFF, default = bg_colour
alarm_led   - middle colour of a block > ALARM,  default = alarm_colour

reflection parameters, not avaimable for circular bars
reflection_alpha    - add a reflection effect (values from 0 to 1) default = 0 = no reflection
                      other values = starting opacity
reflection_scale    - scale of the reflection (default = 1 = height of text)
reflection_length   - length of reflection, define where the opacity will be set to zero
                      calues from 0 to 1, default =1
reflection          - position of reflection, relative to a vertical bar, default="b"
                      possibles values are : "b","t","l","r" for bottom, top, left, right

v1.1 (13 Feb. 2010)  numeric values can be passed instead conky stats with parameters name="", arg = numeric_value
v1.3 (03 March 2010) added parameters radius & angle_bar to draw the bar in a circular way
v2.0 (12 Jul. 2010)  rewrite script + add reflection effects and parameters are now set into tables
-- Rewrite --
V3.0 (3 Nov. 2023)   Rewrite script for use with cava as Spectrum Equalizer in conky. (Koentje & Bleys)
V3.1 (31 dec 2025)   Fixed huge memory leak and cpu usage!! (Koentje)
v3.2 (07 jun 2026)   Rewrote script, uses way less cpu usage on reading cava data stream  (Koentje)

]]


require 'cairo'


-- Scriptname
local SCRIPT_NAME = string.gsub(string.match(debug.getinfo(1, 'S').short_src, "[^/]+$"), '.lua', '')

-- HELPER: Split line with seperator
function split(inputstr, sep)
  if sep == nil then
    sep = '%s'
  end
  local t={}
  for str in string.gmatch(inputstr, '([^'..sep..']+)') do
    table.insert(t, str)
  end
  return t
end

-- Colour helper at module level (used by pattern cache below)
local function rgb_to_r_g_b(col_a)
    return ((col_a[1] / 0x10000) % 0x100) / 255,
           ((col_a[1] / 0x100)   % 0x100) / 255,
           (col_a[1]              % 0x100) / 255,
           col_a[2]
end

-- Pattern cache: keyed by parameter string, cleared on config change.
-- Cached patterns must never be passed to cairo_pattern_destroy by callers.
local pattern_cache = {}

local function invalidate_pattern_cache()
    for _, pat in pairs(pattern_cache) do
        cairo_pattern_destroy(pat)
    end
    pattern_cache = {}
end

-- Solid RGBA pattern, cached for reuse across frames
local function get_rgba_pat(col)
    local key = col[1] .. "_" .. col[2]
    if not pattern_cache[key] then
        pattern_cache[key] = cairo_pattern_create_rgba(rgb_to_r_g_b(col))
    end
    return pattern_cache[key]
end

-- Smooth linear gradient, cached for reuse across frames
local function get_smooth_linear_pat(x0, y0, x1, y1, fg_col, alarm_col, mid_col)
    local key = string.format("sl_%.2f_%.2f_%.2f_%.2f_%x_%.3f_%x_%.3f",
        x0, y0, x1, y1, fg_col[1], fg_col[2], alarm_col[1], alarm_col[2])
    if mid_col then key = key .. "_m" .. #mid_col end
    if not pattern_cache[key] then
        local pat = cairo_pattern_create_linear(x0, y0, x1, y1)
        cairo_pattern_add_color_stop_rgba(pat, 0, rgb_to_r_g_b(fg_col))
        cairo_pattern_add_color_stop_rgba(pat, 1, rgb_to_r_g_b(alarm_col))
        if mid_col then
            for i = 1, #mid_col do
                cairo_pattern_add_color_stop_rgba(pat, mid_col[i][1],
                    rgb_to_r_g_b({mid_col[i][2], mid_col[i][3]}))
            end
        end
        pattern_cache[key] = pat
    end
    return pattern_cache[key]
end

-- Smooth radial gradient, cached for reuse across frames
local function get_smooth_radial_pat(x0, y0, r0, x1, y1, r1, fg_col, alarm_col, mid_col)
    local key = string.format("sr_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f_%x_%.3f_%x_%.3f",
        x0, y0, r0, x1, y1, r1, fg_col[1], fg_col[2], alarm_col[1], alarm_col[2])
    if mid_col then key = key .. "_m" .. #mid_col end
    if not pattern_cache[key] then
        local pat = cairo_pattern_create_radial(x0, y0, r0, x1, y1, r1)
        cairo_pattern_add_color_stop_rgba(pat, 0, rgb_to_r_g_b(fg_col))
        cairo_pattern_add_color_stop_rgba(pat, 1, rgb_to_r_g_b(alarm_col))
        if mid_col then
            for i = 1, #mid_col do
                cairo_pattern_add_color_stop_rgba(pat, mid_col[i][1],
                    rgb_to_r_g_b({mid_col[i][2], mid_col[i][3]}))
            end
        end
        pattern_cache[key] = pat
    end
    return pattern_cache[key]
end


-- Read eq-settings.ini to find cavaout value (path to cava data stream out)
local settings_path = "./eq-settings.ini"
local settings_file = io.open(settings_path, "r")
if settings_file == nil then
    print(SCRIPT_NAME..": \27[31mNo "..settings_path.." found !\27[m")
    os.execute("killall cava-loop")
    os.exit()
else
    for line in settings_file:lines() do
        local key = {line}
        local mykey = split(key[1], "=")
        if mykey[1] == "cavaout" then
            cava_out_path = string.sub(mykey[2],2,-2)
        end
        if mykey[1] == "eqconfig" then
            eq_config_path = string.sub(mykey[2],2,-2)
        end
        if mykey[1] == "showconfig" then
            show_config = string.sub(mykey[2],2,-2)
        end
        if mykey[1] == "showlabel" then
            show_label = string.sub(mykey[2],2,-2)
        end
        if mykey[1] == "live_edit" then
            live_edit = string.sub(mykey[2],2,-2)
        end
    end
    settings_file:close()
end

-- Global config settings
local last_config = ""
local config_loaded = false
local label_show_until = 0
local update_count = 0          -- replaces conky_parse('${updates}') check
local last_cava_values = {}     -- retained on empty reads to suppress write-race blips
local config_check_frame = 10  -- start at 10 to force a file read on the first frame
local last_known_config = ""   -- cached between throttled eq-config reads
local last_config_mtime = nil     -- mtime of active config file at last load (live_edit only)
local _size_logged = false      -- one-time "[name] window: W x H" line
local live_edit_check_frame = 10  -- throttle counter for mtime stat (live_edit only)

-- Load config index from filesystem (alphabetical, auto-includes new configs)
local config_index = {}
local handle = io.popen("ls -1 ./spectrum-configs")
for line in handle:lines() do
    if line ~= "index" then table.insert(config_index, line) end
end
handle:close()
print(SCRIPT_NAME..": Available configs:")
for i, name in ipairs(config_index) do
    print(string.format("  \27[33m%2d\27[m  %s", i, name))
end


-- Mouse click handler: left=next, right=prev (requires own_window_type = 'normal' if 'desktop' passes through)
function conky_mouse_hook(event)
    if event.type ~= "button_down" then return false end
    local total = #config_index
    if total == 0 then return false end
    local current = 1
    local f = io.open(eq_config_path, "r")
    if f then current = tonumber(f:read("*l")) or 1; f:close() end
    if event.button == "left" then       -- left click: next
        current = (current % total) + 1
    elseif event.button == "right" then  -- right click: prev
        current = ((current - 2) % total) + 1
    else
        return false
    end
    local out = io.open(eq_config_path, "w")
    if out then out:write(current); out:close() end
    return true
end



-- MAIN FUNCTION ----------------------------------------------------------------------------------------------------------------------------
function conky_main_bars(arg)
  if conky_window == nil then return "" end

  if not _size_logged and conky_window.width > 0 then
      print(string.format("[%s] window: %d x %d",
          conky_config:match("([^/]+)$"), conky_window.width, conky_window.height))
      _size_logged = true
  end

    -- READ SELECTED CONFIG FROM RAM (arg overrides, e.g. ${lua main_bars blocks})
    -- Throttled: eq-config file is only re-read every 10 frames (~600ms) since it
    -- only changes on mouse click. last_known_config holds the value between reads.
    local config = arg or last_known_config
    if not arg then
        config_check_frame = config_check_frame + 1
        if config_check_frame >= 10 then
            config_check_frame = 0
            local sel_file = io.open(eq_config_path, "r")
            if sel_file then
                local num = tonumber(sel_file:read("*l"))
                sel_file:close()
                if num and config_index[num] then
                    last_known_config = config_index[num]
                    config = last_known_config
                end
            end
        end
    end
    if config == "" then config = config_index[1] or "" end

    -- CONFIG OUTPUT TO STDOUT
    if show_config == "on" and config ~= "" then
      local cfg_path = "./spectrum-configs/" .. config
      local f = io.open(cfg_path, "r")
      if f ~= nil then
        f:close()
        print("Loading spectrum config: \27[32m" .. config .."\27[m")
        print("__________________________________\n")
        os.execute("cat ".. cfg_path .." | awk -F'--' '{print $1}' | awk -F'=' '{print \"\27[97;3m\" $1 \"\27[31m=\27[32m\" $2 \"\27[m\" }'")
        print("__________________________________\n")
        show_config = "off"
      end
    end


    -- LOAD EXTERNAL CONFIG (on name change, or on mtime change when live_edit="on")
    local cfg_path = "./spectrum-configs/" .. config
    local reload = not config_loaded or last_config ~= config

    -- live_edit: throttled mtime poll instead of reloading every frame
    if live_edit == "on" and not reload then
        live_edit_check_frame = live_edit_check_frame + 1
        if live_edit_check_frame >= 10 then
            live_edit_check_frame = 0
            local mt = io.popen("stat -c %Y '" .. cfg_path .. "' 2>/dev/null")
            local mtime = mt:read("*l")
            mt:close()
            if mtime and mtime ~= last_config_mtime then reload = true end
        end
    end

    if reload then
        local chunk = loadfile(cfg_path)  -- returns nil if file missing
        if chunk then
            chunk() -- Executes config and sets global variables
            invalidate_pattern_cache()  -- colors/dimensions changed; rebuild on next draw
            last_config = config
            label_show_until = os.time() + 5
            le = (live_edit == "on") and "(\27[31;5mLIVE EDIT\27[m)" or ""
            if live_edit == "on" then
                local mt = io.popen("stat -c %Y '" .. cfg_path .. "' 2>/dev/null")
                last_config_mtime = mt:read("*l")
                mt:close()
            end
            config_loaded = true
            print(SCRIPT_NAME..": \27[32m" .. config .. "\27[m " .. le)
        end
    end


   -- READ CAVA DATA (The high-speed optimization)
   -- On an empty read (shell truncated file before finishing write), retain the
   -- previous frame's values to avoid a one-frame drop-to-zero blip.
   local cava_values = last_cava_values
   local cava_file = io.open(cava_out_path, "r")
   if cava_file then
       local line = cava_file:read("*l")
       cava_file:close()
       if line and line ~= "" then
           cava_values = {}
           for val in string.gmatch(line, "%S+") do
             table.insert(cava_values, tonumber(val) or 0)
           end
           last_cava_values = cava_values
       end
   end


   -- SETUP CAIRO CONTEXT
   local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, conky_window.width, conky_window.height)
   cr = cairo_create(cs)


   -- RENDER BAR LOOP
   update_count = update_count + 1
   if update_count > 3 then
      for i = 1, (bars or 0) do
          local k = {
                     value = cava_values[i] or 0,
                     max = max or 1000,
                     cap = cap or "b",
                     x = x + (i - 1) * (width + (barspaces or 2)),
                     y = y,
                     barspaces = barspaces or 2,
                     angle_bar = angle_bar or 0,
                     radius = radius or 0,
                     fg_colour = fg_colour,
                     bg_colour = bg_colour,
                     mid_colour = mid_colour,
                     alarm_colour = alarm_colour,
                     smooth = smooth,
                     blockspaces = blockspaces or 2,
                     blocks = blocks or 10,
                     height = height or 5,
                     width = width or 20,
                     angle = angle or 0,
                     skew_x = skew_x or 0,
                     skew_y = skew_y or 0,
                     reflection = reflection or "b",
                     reflection_alpha = reflection_alpha or 0,
                     reflection_length = reflection_length or 0,
                     reflection_scale = reflection_scale or 1,
                     alarm = alarm,
                    }
          draw_multi_bar_graph(k)
      end
   end


  -- CONFIG LABEL (enabled via showlabel="on"/"auto" in eq-settings.ini)
  if config ~= "" and fg_colour and (show_label == "on" or (show_label == "auto" and os.time() < label_show_until)) then
      local r = ((fg_colour[1] / 0x10000) % 0x100) / 255
      local g = ((fg_colour[1] / 0x100)   % 0x100) / 255
      local b = (fg_colour[1]              % 0x100) / 255
      cairo_select_font_face(cr, "Noto Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
      cairo_set_font_size(cr, 10)
      cairo_set_source_rgba(cr, r, g, b, 1)
      local extents = cairo_text_extents_t:create()
      cairo_text_extents(cr, config, extents)
      cairo_move_to(cr, (conky_window.width - extents.width) / 2, conky_window.height - 4)
      cairo_show_text(cr, config)
  end


  -- CLEANUP
  cairo_destroy(cr)
  cairo_surface_destroy(cs)
  return ""
end




-- DRAW MULTI BARS ---------------------------------------------------------------------------------
function draw_multi_bar_graph(t)
  cairo_save(cr)

  -- shared upvalues for nested functions (were previously implicit globals)
  local delta, pct, pcb, circle, cblock

  --check values
  if t.max==nil then
    print ("No maximum value defined, use 'max'")
    return
  end

   -- Defaults for fields not guaranteed by conky_main_bars (colours, alarm, smooth, mode)
   -- Numeric/structural fields (blocks, height, width, etc.) are pre-filled with 'or'
   -- defaults in the k table, so their nil-checks are omitted here.
   if t.mode == nil then t.mode="straight" end
   if t.mode == "round" then
     circle = 360/bars
     cblock = circle/blocks
   end
   t.angle    = t.angle    * math.pi / 180
   t.angle_bar = t.angle_bar * math.pi / 360  -- half angle
   t.skew_x   = math.pi * t.skew_x / 180
   t.skew_y   = math.pi * t.skew_y / 180

   --line cap style
   local cap = "b"
   for i,v in ipairs({"s","r","b"}) do
     if v==t.cap then cap=v end
   end
   delta = 0
   if t.cap=="r" or t.cap=="s" then delta = t.height end
   if cap=="s" then      cap = CAIRO_LINE_CAP_SQUARE
   elseif cap=="r" then  cap = CAIRO_LINE_CAP_ROUND
   else                  cap = CAIRO_LINE_CAP_BUTT
   end

   --colours (passed directly from config globals; may be nil if config omits them)
   if t.bg_colour == nil     then t.bg_colour = {0x00FF00,0.5} end
   if #t.bg_colour ~=2       then t.bg_colour = {0x00FF00,0.5} end
   if t.fg_colour == nil     then t.fg_colour = {0x00FF00,1} end
   if #t.fg_colour ~=2       then t.fg_colour = {0x00FF00,1} end
   if t.alarm_colour == nil  then t.alarm_colour = t.fg_colour end
   if #t.alarm_colour ~=2    then t.alarm_colour = t.fg_colour end

   if t.mid_colour ~= nil then
     for i=1, #t.mid_colour do
         if #t.mid_colour[i]~=3 then
         print ("error in mid_color table")
         t.mid_colour[i]={1,0xFFFFFF,1}
         end
     end
   end

   if t.bg_led ~= nil and #t.bg_led ~=2     then t.bg_led = t.bg_colour end
   if t.fg_led ~= nil and #t.fg_led ~=2     then t.fg_led = t.fg_colour end
   if t.alarm_led ~= nil and #t.alarm_led~=2 then t.alarm_led = t.fg_led end

   if t.alarm  == nil then t.alarm  = t.max  end
   if t.smooth == nil then t.smooth = false  end


  -- LED pattern helpers: position-dependent, not suitable for caching
  local function create_led_linear_gradient(x0,y0,x1,y1,col_alp,col_led)
    local pat = cairo_pattern_create_linear(x0,y0,x1,y1)
    cairo_pattern_add_color_stop_rgba(pat, 0.0, rgb_to_r_g_b(col_alp))
    cairo_pattern_add_color_stop_rgba(pat, 0.5, rgb_to_r_g_b(col_led))
    cairo_pattern_add_color_stop_rgba(pat, 1.0, rgb_to_r_g_b(col_alp))
    return pat
  end

  local function create_led_radial_gradient(x0,y0,r0,x1,y1,r1,col_alp,col_led,mode)
    local pat = cairo_pattern_create_radial(x0,y0,r0,x1,y1,r1)
    if mode==3 then
      cairo_pattern_add_color_stop_rgba(pat, 0,   rgb_to_r_g_b(col_alp))
      cairo_pattern_add_color_stop_rgba(pat, 0.5, rgb_to_r_g_b(col_led))
      cairo_pattern_add_color_stop_rgba(pat, 1,   rgb_to_r_g_b(col_alp))
    else
      cairo_pattern_add_color_stop_rgba(pat, 0, rgb_to_r_g_b(col_led))
      cairo_pattern_add_color_stop_rgba(pat, 1, rgb_to_r_g_b(col_alp))
    end
    return pat
  end


  local function draw_single_bar()
    --this function is used for bars with a single block (blocks=1) but
    --the drawing is cut in 3 blocks : value/alarm/background
    --not available for circular bar
    local function create_pattern(col_alp,col_led,bg)
      if not t.smooth then
        if bg then
          return get_rgba_pat(t.bg_colour)
        else
          return get_smooth_linear_pat(t.width/2, 0, t.width/2, -t.height,
              t.fg_colour, t.alarm_colour, t.mid_colour)
        end
      end
      return nil
    end

    local y1=-t.height*pct/100
    local y2=nil
    if pct>(100*t.alarm/t.max) then
      y1 = -t.height*t.alarm/100
      y2 = -t.height*pct/100
      if t.smooth then y1=y2 end
    end

    if t.angle_bar==0 then

      --block for fg value
      local pat = create_pattern(t.fg_colour,t.fg_led,false)
      cairo_set_source(cr,pat)
      cairo_rectangle(cr,0,0,t.width,y1)
      cairo_fill(cr)

      -- block for alarm value
      local y3
      if not t.smooth and y2 ~=nil then
        pat = create_pattern(t.alarm_colour,t.alarm_led,false)
        cairo_set_source(cr,pat)
        cairo_rectangle(cr,0,y1,t.width,y2-y1)
        cairo_fill(cr)
        y3=y2
      else
        y2,y3=y1,y1
      end
      -- block for bg value (all patterns above are cached; no destroy needed)
      cairo_rectangle(cr,0,y2,t.width,-t.height-y3)
      pat = create_pattern(t.bg_colour,t.bg_led,true)
      cairo_set_source(cr,pat)
      cairo_fill(cr)
    end
  end  --end single bar



  local function draw_multi_bar()

    -- FAST PATH: solid color, straight bars
    -- Batch all blocks of each color group into one path+stroke instead of one per block.
    -- Reduces Cairo stroke calls from (bars*blocks) down to at most (bars*3) per frame.
    if t.angle_bar==0 and not t.smooth and not t.led_effect then
      local bg_pts, fg_pts, alarm_pts = {}, {}, {}
      for pt = 1, t.blocks do
        local y1 = -(pt-1)*(t.height+t.blockspaces)
        if (pct>=(100/t.blocks) or pct>0) and pct>=(pcb*(pt-1)) then
          if pct>=(100*t.alarm/t.max) and (pcb*pt)>(100*t.alarm/t.max) then
            alarm_pts[#alarm_pts+1] = y1
          else
            fg_pts[#fg_pts+1] = y1
          end
        else
          bg_pts[#bg_pts+1] = y1
        end
      end

      local function stroke_group(pts, col)
        if #pts == 0 or col[2] == 0 then return end
        cairo_set_source(cr, get_rgba_pat(col))
        for _, y1 in ipairs(pts) do
          cairo_move_to(cr, 0, y1)
          cairo_line_to(cr, t.width, y1)
        end
        cairo_stroke(cr)
      end

      stroke_group(bg_pts,    t.bg_colour)
      stroke_group(fg_pts,    t.fg_colour)
      stroke_group(alarm_pts, t.alarm_colour)
      return
    end

    -- GENERAL PATH: per-block rendering for smooth, LED effects, and circular bars.
    -- 'owned' tracks whether we must destroy the pattern after use (cached patterns must not be destroyed).
    for pt = 1,t.blocks do
      local y1 = -(pt-1)*(t.height+t.blockspaces)
      local light_on=false

      local col_alp = t.bg_colour
      local col_led = t.bg_led
      if pct>=(100/t.blocks) or pct>0 then
        if pct>=(pcb*(pt-1)) then
          light_on = true
          col_alp = t.fg_colour
          col_led = t.fg_led
          if pct>=(100*t.alarm/t.max) and (pcb*pt)>(100*t.alarm/t.max) then
            col_alp = t.alarm_colour
            col_led = t.alarm_led
          end
        end
      end

      -- skip fully transparent blocks (e.g. bg_colour alpha=0 configs like fade/flames)
      if col_alp[2] == 0 then goto continue end

      local pat
      local owned = true  -- must we cairo_pattern_destroy after use?

      if not t.smooth then
        if t.angle_bar==0 then
          if t.led_effect=="e" then
            pat = create_led_linear_gradient(-delta, 0, delta+t.width, 0, col_alp, col_led)
          elseif t.led_effect=="a" then
            pat = create_led_linear_gradient(t.width/2, -t.height/2+y1, t.width/2, t.height/2+y1, col_alp, col_led)
          elseif t.led_effect=="r" then
            pat = create_led_radial_gradient(t.width/2, y1, 0, t.width/2, y1, t.width/1.5, col_alp, col_led, 2)
          else
            pat = get_rgba_pat(col_alp)
            owned = false
          end
        else
          if t.led_effect=="a" then
            pat = create_led_radial_gradient(0, 0, t.radius+(t.height+t.blockspaces)*(pt-1), 0, 0, t.radius+(t.height+t.blockspaces)*(pt), col_alp, col_led, 3)
          else
            pat = get_rgba_pat(col_alp)
            owned = false
          end
        end
      else
        -- Smooth: gradient created once per unique parameter set and cached across frames
        if light_on then
          if t.angle_bar==0 then
            pat = get_smooth_linear_pat(t.width/2, t.height/2, t.width/2,
                -(t.blocks-0.5)*(t.height+t.blockspaces),
                t.fg_colour, t.alarm_colour, t.mid_colour)
          else
            pat = get_smooth_radial_pat(0, 0, (t.height+t.blockspaces),
                0, 0, (t.blocks+1)*(t.height+t.blockspaces),
                t.fg_colour, t.alarm_colour, t.mid_colour)
          end
        else
          pat = get_rgba_pat(t.bg_colour)
        end
        owned = false
      end

      cairo_set_source(cr, pat)
      if owned then cairo_pattern_destroy(pat) end

      --draw a block
      if t.angle_bar==0 then
        cairo_move_to(cr,0,y1)
        cairo_line_to(cr,t.width,y1)
      else
        cairo_arc(cr, 0, 0,
          t.radius+(t.height+t.blockspaces)*(pt)-t.height/2,
          -t.angle_bar -math.pi/2,
           t.angle_bar -math.pi/2)
      end
      cairo_stroke(cr)
      ::continue::
    end
  end


  local function setup_bar_graph()
    --function used to retrieve the value to display and to set the cairo structure
    if t.blocks ~=1 then t.y=t.y-t.height/2 end

    pct = 100*t.value/t.max
    pcb = 100/t.blocks

    cairo_set_line_width (cr, t.height)
    cairo_set_line_cap  (cr, cap)
    cairo_translate(cr,t.x,t.y)
    cairo_rotate(cr,t.angle)

    if t.skew_x ~= 0 or t.skew_y ~= 0 then
      local matrix0 = cairo_matrix_t:create(); tolua.takeownership(matrix0)
      cairo_matrix_init (matrix0, 1,t.skew_y,t.skew_x,1,0,0)
      cairo_transform(cr,matrix0)
    end


    --call the drawing function for blocks
    if t.blocks==1 and t.angle_bar==0 then
      draw_single_bar()
      if t.reflection=="t" or t.reflection=="b" then cairo_translate(cr,0,-t.height) end
    else
      draw_multi_bar()
    end

    --call the drawing function for reflection and prepare the mask used
    if t.reflection_alpha>0 and t.angle_bar==0 then
      local pat2
      local matrix1 = cairo_matrix_t:create(); tolua.takeownership(matrix1)
      if t.angle_bar==0 then
        local pts={-delta/2,(t.height+t.blockspaces)/2,t.width+delta,-(t.height+t.blockspaces)*(t.blocks)}
        if t.reflection=="t" then
          cairo_matrix_init (matrix1,1,0,0,-t.reflection_scale,0,-(t.height+t.blockspaces)*(t.blocks-0.5)*2*(t.reflection_scale+1)/2)
          pat2 = cairo_pattern_create_linear (t.width/2,-(t.height+t.blockspaces)*(t.blocks),t.width/2,(t.height+t.blockspaces)/2)
        elseif t.reflection=="r" then
          cairo_matrix_init (matrix1,-t.reflection_scale,0,0,1,delta+2*t.width,0)
          pat2 = cairo_pattern_create_linear (delta/2+t.width,0,-delta/2,0)
        elseif t.reflection=="l" then
          cairo_matrix_init (matrix1,-t.reflection_scale,0,0,1,-delta,0)
          pat2 = cairo_pattern_create_linear (-delta/2,0,delta/2+t.width,-0)
        else --bottom
          cairo_matrix_init (matrix1,1,0,0,-1*t.reflection_scale,0,(t.height+t.blockspaces)*(t.reflection_scale+1)/2)
          pat2 = cairo_pattern_create_linear (t.width/2,(t.height+t.blockspaces)/2,t.width/2,-(t.height+t.blockspaces)*(t.blocks))
        end

        cairo_transform(cr,matrix1)

        if t.blocks==1 and t.angle_bar==0 then
          draw_single_bar()
          cairo_translate(cr,0,-t.height/2)
        else
          draw_multi_bar()
        end

        cairo_set_line_width(cr,0.01)
        cairo_pattern_add_color_stop_rgba (pat2, 0,0,0,0,1-t.reflection_alpha)
        cairo_pattern_add_color_stop_rgba (pat2, t.reflection_length,0,0,0,1)
        cairo_rectangle(cr,pts[1],pts[2],pts[3],pts[4])
        cairo_clip_preserve(cr)
        cairo_set_operator(cr,CAIRO_OPERATOR_CLEAR)
        cairo_stroke(cr)
        cairo_mask(cr,pat2)
        cairo_pattern_destroy(pat2)
        cairo_set_operator(cr,CAIRO_OPERATOR_OVER)
      end
    end --reflection


  end --setup_bar_graph()


  --start here !
  setup_bar_graph()
  cairo_restore(cr)

 return "" -- Keep conky happy with some return output to text block
end
