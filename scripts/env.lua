-- env.lua - the one .env parser for the enigma suite
-- enigma-config.sh writes values unquoted; surrounding quotes are tolerated
-- here so a hand-edited .env still works. Parsed once per Lua state.
-- v1 2026-07-04 @rew62

local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma"

local vars
local function load()
    if vars then return vars end
    vars = {}
    local f = io.open(ENIGMA_DIR .. "/.env", "r")
    if f then
        for line in f:lines() do
            line = line:match("^([^#]*)") or ""
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k and v ~= "" then
                vars[k] = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v
            end
        end
        f:close()
    end
    return vars
end

local M = {}

-- Return .env value for key, or fallback when the key is missing/empty.
function M.get(key, fallback)
    local v = load()[key]
    if v ~= nil and v ~= "" then return v end
    return fallback
end

return M
