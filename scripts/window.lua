-- window.lua - Ctrl+click window management for conky widgets
--
-- Ctrl+left-click : save current window position to the rc file (top_left alignment)
-- Ctrl+right-click: kill this conky instance
--
-- Usage in loadall.lua:
--   local window = require("window")
--   -- in conky_mouse_hook(event), before widget-specific handling:
--   if window.handle_mouse(event) then return true end
--
-- The rc file must have lua_mouse_hook = 'mouse_hook' in conky.config.
--
-- v1 2026-07-04 @rew62

local M = {}

local function patch_rc(rc, wx, wy)
    local f = io.open(rc, "r")
    if not f then
        print("save-pos: cannot open " .. rc)
        return
    end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()

    -- Detect whether originals are already commented out from a prior save
    local already_saved = false
    for _, line in ipairs(lines) do
        if line:match("^%s*%-%-%s*alignment%s*=") then
            already_saved = true
            break
        end
    end

    local out = {}
    if already_saved then
        -- Update only the active (non-commented) alignment / gap_x / gap_y lines
        for _, line in ipairs(lines) do
            if line:match("^%s*alignment%s*=") then
                line = line:gsub("^(%s*alignment%s*=%s*)[^,]*(,)", "%1'top_left'%2")
            elseif line:match("^%s*gap_x%s*=") then
                line = line:gsub("^(%s*gap_x%s*=%s*)[^,]*(,)", "%1" .. wx .. "%2")
            elseif line:match("^%s*gap_y%s*=") then
                line = line:gsub("^(%s*gap_y%s*=%s*)[^,]*(,)", "%1" .. wy .. "%2")
            end
            out[#out + 1] = line
        end
    else
        -- First save: comment out originals, insert new block after gap_y
        local indent = "    "
        for _, line in ipairs(lines) do
            if line:match("^%s*alignment%s*=") then
                indent = line:match("^(%s*)") or "    "
                out[#out + 1] = line:gsub("^(%s*)(alignment%s*=)", "%1-- %2")
            elseif line:match("^%s*gap_x%s*=") then
                out[#out + 1] = line:gsub("^(%s*)(gap_x%s*=)", "%1-- %2")
            elseif line:match("^%s*gap_y%s*=") then
                out[#out + 1] = line:gsub("^(%s*)(gap_y%s*=)", "%1-- %2")
                out[#out + 1] = indent .. "-- Position moved via Alt+drag, saved via Ctrl+left-click"
                out[#out + 1] = indent .. "alignment = 'top_left',"
                out[#out + 1] = indent .. "gap_x = " .. wx .. ","
                out[#out + 1] = indent .. "gap_y = " .. wy .. ","
            else
                out[#out + 1] = line
            end
        end
    end

    local wf = io.open(rc, "w")
    if not wf then
        print("save-pos: cannot write " .. rc)
        return
    end
    wf:write(table.concat(out, "\n") .. "\n")
    wf:close()
end

function M.handle_mouse(event)
    if WINDOW_MOUSE_HOOK == false then return false end
    if event.type ~= "button_down" then return false end

    if event.button == "left" and event.mods and event.mods.control then
        -- NOTE: y_abs is bugged in conky 1.19.8 (always 0), so xdotool getmouselocation
        -- is used to get absolute cursor position. When fixed upstream, replace with:
        --   local wx = event.x_abs - event.x
        --   local wy = event.y_abs - event.y
        local f = io.popen("xdotool getmouselocation 2>/dev/null")
        local out = f and f:read("*all") or ""
        if f then f:close() end
        local mx = tonumber(out:match("x:(%d+)")) or 0
        local my = tonumber(out:match("y:(%d+)")) or 0
        local wx = mx - event.x
        local wy = my - event.y
        print(string.format("save-pos: (%d,%d) -> %s", wx, wy, conky_config))
        patch_rc(conky_config, wx, wy)
        return true
    end

    if event.button == "right" and event.mods and event.mods.control then
        os.execute(string.format("pkill -f '%s' &", conky_config))
        return true
    end

    return false
end

return M
