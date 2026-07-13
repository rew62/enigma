-- surface.lua - backend-agnostic cairo drawing surface for conky widgets
--
-- get() prefers conky_surface() (conky >= 1.23), which works on both X11
-- and Wayland but returns a conky-managed surface: valid only for the
-- current draw cycle, and must NOT be destroyed by us. The cairo_xlib
-- fallback (the only path on prod 1.19.8) is a surface we create, so we
-- must destroy it. get() returns an `owns` flag so put() can tell the two
-- apart -- always release through put(), never call cairo_surface_destroy()
-- on a surface from get() directly.
--
-- The cairo_t context is the caller's in both cases: cairo_destroy() it
-- unconditionally at the call site.
--
-- v1 2026-07-13 @rew62

pcall(require, 'cairo')
pcall(require, 'cairo_xlib')  -- conky 1.22+ splits xlib fns into cairo_xlib; absent on Wayland-only builds

local M = {}

-- Returns surface, owns -- or nil if there is nothing to draw on yet.
function M.get()
    if conky_surface then
        local s = conky_surface()
        if s then return s, false end
    end
    if conky_window and cairo_xlib_surface_create then
        if conky_window.width == 0 or conky_window.height == 0 then
            return nil, false
        end
        return cairo_xlib_surface_create(
            conky_window.display, conky_window.drawable,
            conky_window.visual, conky_window.width,
            conky_window.height), true
    end
    return nil, false
end

function M.put(cs, owns)
    if owns and cs then cairo_surface_destroy(cs) end
end

return M
