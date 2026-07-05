-- scripts/lyrics-loadall.lua - Loads and calls Lua Modules
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

-- ============================================================
-- conky_main  (lua_draw_hook_pre)
-- Draws: background (shared draw_bg.lua)
-- ============================================================
function conky_main()
    if conky_window == nil then return end

    draw_bg()

    log_window_size()
end
