-- scripts/nowplaying-loadall.lua
-- loads and calls: draw_bg (shared), nowplaying, volume
-- v1 2026-07-04 @rew62

package.path = "./scripts/?.lua;" .. package.path
    .. ";" .. (os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma") .. "/scripts/?.lua"

local function try_require(modname)
    local ok, result = pcall(require, modname)
    if not ok then
        print("Error loading " .. modname .. ": " .. tostring(result))
    end
    return ok
end

try_require("draw_bg")
try_require("nowplaying")
try_require("volume")

-- ============================================================
-- conky_main  (lua_draw_hook_pre)
-- Draws: background, nowplaying section, volume section
-- ============================================================
function conky_main()
    if conky_window == nil then return end

    -- 1. Background (shared draw_bg.lua)
    draw_bg()

    -- shared Cairo surface for all remaining lua drawing
    local cs = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable,
        conky_window.visual, conky_window.width, conky_window.height)
    local cr = cairo_create(cs)

    -- 2. Now Playing section  (top of window, y-offset = 15)
    draw_nowplaying(cr, 15)

    -- 3. Volume section  (below nowplaying, y-offset = 240)
    draw_volume(cr, 240)

    cairo_destroy(cr)
    cairo_surface_destroy(cs)

    log_window_size()
end

-- ── Shift+click: toggle sibling music2 scripts (lyrics / eq) ─────────────────
-- music2 is flat, so eq.rc / start-lyrics-conky.sh are direct siblings of
-- nowplaying's own cwd (no more ../eq, ../lyrics nesting).

-- the bracket around the first letter ("[l]yrics" etc.) keeps pgrep/pkill -f
-- from matching their own invoking shell's command line, which otherwise
-- contains the literal search pattern and self-matches as a false positive
local function toggle_lyrics()
    local running = os.execute("pgrep -f '[l]yrics\\.rc' >/dev/null 2>&1")
    if running then
        os.execute("pkill -f '[s]tart-lyrics-conky\\.sh' 2>/dev/null")
        os.execute("pkill -f '[a]ctive-player\\.sh' 2>/dev/null")
        os.execute("pkill -f '[l]yrics\\.rc' 2>/dev/null")
    else
        os.execute("setsid bash start-lyrics-conky.sh >/dev/null 2>&1 &")
    end
end

local function toggle_eq()
    local running = os.execute("pgrep -f '[e]q\\.rc' >/dev/null 2>&1")
    if running then
        os.execute("pkill -f '[e]q\\.rc' 2>/dev/null")
    else
        -- Wayland: uncomment to force conky onto its X11/XWayland backend
        -- (native Wayland backend lacks the ARGB/click-through support this
        -- widget needs); no-op on a real X11 session.
        -- os.execute("setsid env WAYLAND_DISPLAY= XDG_SESSION_TYPE=x11 conky -c eq.rc >/dev/null 2>&1 &")
        os.execute("setsid conky -c eq.rc >/dev/null 2>&1 &")
    end
end

-- ── Mouse / click handling (active only when lua_mouse_hook is set) ──────────
--
-- Volume section geometry mirrors volume.lua's draw_volume(cr, 240):
-- margin=2, icon_sz=16, bar_x = margin+icon_sz+4, bar_end = win_w-margin-icon_sz-4
--
-- Click zones:
--   shift+left-click      → anywhere on widget: toggle lyrics
--   shift+right-click     → anywhere on widget: toggle eq
--   x < bar_x            → mute icon:  toggle mute
--   bar_x ≤ x ≤ bar_end  → bar:        set volume to click position
--   x > bar_end          → vol icon:   step +5%
--   scroll up/down       → anywhere in section: ±2%
--   right-click          → anywhere in section: toggle mute

local VOL_SECTION_Y = 234   -- y above which non-shift clicks are ignored (matches the divider)

function conky_mouse_hook(event)
    local t = event.type
    if t == "mouse_move" or t == "mouse_enter" or t == "mouse_leave" then return false end

    if t == "button_down" and event.mods and event.mods.shift then
        if event.button == "left" then
            toggle_lyrics()
            return true
        elseif event.button == "right" then
            toggle_eq()
            return true
        end
    end

    local x, y = event.x, event.y
    if y < VOL_SECTION_Y then return false end

    -- scroll anywhere in the volume section: conky reports the wheel as type
    -- "mouse_scroll" with a direction field (scroll_up/scroll_down types
    -- don't exist in any conky version)
    if t == "mouse_scroll" then
        if event.direction == "up" then
            os.execute("pactl set-sink-volume @DEFAULT_SINK@ +2% &")
        elseif event.direction == "down" then
            os.execute("pactl set-sink-volume @DEFAULT_SINK@ -2% &")
        end
        return true
    elseif t ~= "button_down" then
        return false
    end

    local win_w   = conky_window and conky_window.width or 154
    local margin  = 2
    local icon_sz = 16
    local bar_x   = margin + icon_sz + 4
    local bar_end = win_w - margin - icon_sz - 4

    if event.button == "right" then
        os.execute("pactl set-sink-mute @DEFAULT_SINK@ toggle &")
        return true
    end

    if event.button ~= "left" then return false end

    if x < bar_x then
        -- mute icon: toggle mute
        os.execute("pactl set-sink-mute @DEFAULT_SINK@ toggle &")
    elseif x <= bar_end then
        -- click on bar: set volume proportionally
        local pct = math.floor(((x - bar_x) / (bar_end - bar_x)) * 100 + 0.5)
        pct = math.max(0, math.min(100, pct))
        os.execute(string.format("pactl set-sink-volume @DEFAULT_SINK@ %d%% &", pct))
    else
        -- vol icon: step up 5%
        os.execute("pactl set-sink-volume @DEFAULT_SINK@ +5% &")
    end
    return true
end
