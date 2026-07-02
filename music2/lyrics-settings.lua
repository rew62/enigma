-- lyrics-settings.lua
-- v1 2026-07-04 @rew62

package.path = "./scripts/?.lua;" .. package.path
    .. ";" .. (os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma") .. "/scripts/?.lua"
