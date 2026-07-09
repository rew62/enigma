-- met_fetch.lua - Met.no locationforecast fetcher, fallback for nws_fetch.lua
-- when the NWS /points lookup 404s (location outside US coverage).
-- Produces day records in the same shape as nws_fetch's parse_forecast so
-- consumers (arc6, draw_nws_forecast_small, draw_tempbar) need no changes.
-- Atomic-safe: tmp→mv writes + mkdir lock, same patterns as nws_fetch.lua
-- v1 2026-07-09 @rew62

local ENIGMA_DIR = os.getenv("ENIGMA_DIR") or (os.getenv("HOME") or "") .. "/.conky/enigma"
package.path = package.path .. ";./?.lua;../?.lua;" .. ENIGMA_DIR .. "/scripts/?.lua"
local env = require("env")

local LATITUDE  = env.get("LAT", "40.7128")
local LONGITUDE = env.get("LON", "-74.0060")
local UNITS     = env.get("UNITS", "imperial")

-- Met.no ToS requires an identifying User-Agent with a contact point
local USER_AGENT = "enigma-conky/1.0 (https://github.com/rew62/enigma)"

local FCST_CACHE_FILE = "/dev/shm/conky/met_forecast.json"
local FCST_CACHE_MINS = 60   -- met.no forecast models update roughly hourly
local DAYS_WANTED     = 5

------------------------------------------------------------------------
-- JSON
------------------------------------------------------------------------
local cjson = nil
local ok, lib = pcall(require, "cjson")
if ok then
    cjson = lib
else
    local ok2, lib2 = pcall(require, "json")
    if ok2 then
        cjson = lib2
    else
        print("FATAL: no JSON library found")
    end
end

------------------------------------------------------------------------
-- File helpers
------------------------------------------------------------------------
local function file_mtime(path)
    local h = io.popen("stat -c %Y " .. path .. " 2>/dev/null")
    if not h then return nil end
    local t = tonumber(h:read("*l")); h:close()
    return t
end

local function file_age_minutes(path)
    local t = file_mtime(path)
    if not t then return math.huge end
    return (os.time() - t) / 60
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function curl_get(url, out_file)
    local cmd = string.format(
        'curl -sfL --max-time 15 -A "%s" "%s" -o "%s"',
        USER_AGENT, url, out_file)
    local ret = os.execute(cmd)
    if type(ret) == "boolean" then return ret end
    return (ret == 0)
end

local function try_mkdir(path)
    local ret = os.execute("mkdir " .. path .. " 2>/dev/null")
    if type(ret) == "boolean" then return ret end
    return (ret == 0)
end

------------------------------------------------------------------------
-- Time: met.no timeseries is UTC; bucket into local calendar days.
-- Uses the machine's timezone, which matches the forecast location in
-- the normal case of a user viewing their own weather.
------------------------------------------------------------------------
local _utc_off = nil
local function utc_offset()
    if _utc_off then return _utc_off end
    local now = os.time()
    local u = os.date("!*t", now)
    u.isdst = false
    _utc_off = os.difftime(now, os.time(u))
    return _utc_off
end

local function iso_to_epoch(s)
    local y, mo, d, h, mi = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = 0, isdst = false }
           + utc_offset()
end

------------------------------------------------------------------------
-- Symbol code → canonical icon token (keys of the drawers' NWS_TO_METNO
-- maps). Pattern checks are ordered most-specific first; met.no compound
-- codes like "lightrainshowersandthunder" all funnel to thunderstorm.
------------------------------------------------------------------------
local function canonical_from_symbol(code, is_day)
    local base = code:gsub("_day$", ""):gsub("_night$", ""):gsub("_polartwilight$", "")
    local suffix = is_day and "_day" or "_night"
    if base:find("thunder")      then return "thunderstorm" end
    if base:find("sleet")        then return "sleet" end
    if base:find("snow")         then return "snow" end
    if base:find("showers")      then return "showers" end
    if base:find("rain")         then return "rain" end
    if base == "fog"             then return "fog" end
    if base == "clearsky"        then return "clear" .. suffix end
    if base == "fair"            then return "few_clouds" .. suffix end
    if base == "partlycloudy"    then return "scattered_clouds" .. suffix end
    if base == "cloudy"          then return "overcast" end
    return "scattered_clouds" .. suffix
end

local SHORT_TEXT = {
    clearsky = "Clear", fair = "Mostly Sunny", partlycloudy = "Partly Cloudy",
    cloudy = "Cloudy", fog = "Fog",
}

local function short_text(code)
    local base = code:gsub("_day$", ""):gsub("_night$", ""):gsub("_polartwilight$", "")
    if SHORT_TEXT[base] then return SHORT_TEXT[base] end
    if base:find("thunder") then return "Thunderstorms" end
    local qual = base:find("^light") and "Light " or base:find("^heavy") and "Heavy " or ""
    local kind = base:find("sleet") and "Sleet" or base:find("snow") and "Snow" or "Rain"
    local showers = base:find("showers") and " Showers" or ""
    return qual .. kind .. showers
end

local DIRS = { "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
               "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW" }
local function compass(deg)
    if type(deg) ~= "number" then return "" end
    return DIRS[math.floor(deg / 22.5 + 0.5) % 16 + 1]
end

------------------------------------------------------------------------
-- Module
------------------------------------------------------------------------
local M = {}

function M.cache_mtime()
    return file_mtime(FCST_CACHE_FILE)
end

-- Fetch forecast JSON (cached, atomic write, single-fetch lock)
function M.fetch_forecast()
    if file_age_minutes(FCST_CACHE_FILE) < FCST_CACHE_MINS then
        return read_file(FCST_CACHE_FILE)
    end

    local lock = FCST_CACHE_FILE .. ".lock"

    -- Break stale locks left by a crashed caller (curl max-time is 15s; 60s is safe)
    if file_age_minutes(lock) > 1 then
        os.execute("rmdir " .. lock .. " 2>/dev/null")
    end

    -- Atomic lock: mkdir succeeds for exactly one caller; others return existing cache
    if not try_mkdir(lock) then
        return read_file(FCST_CACHE_FILE)
    end

    local url = string.format(
        "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%s&lon=%s",
        LATITUDE, LONGITUDE)
    local tmp = FCST_CACHE_FILE .. ".tmp"

    local function do_fetch()
        if curl_get(url, tmp) then
            local raw = read_file(tmp)
            local ok, data = pcall(cjson.decode, raw or "")
            if ok and data and data.properties and data.properties.timeseries then
                os.execute("mv " .. tmp .. " " .. FCST_CACHE_FILE)
            else
                print("met_fetch: forecast response invalid, keeping old cache")
                os.execute("rm -f " .. tmp)
            end
        else
            print("met_fetch: forecast fetch failed")
            os.execute("rm -f " .. tmp)
        end
    end

    pcall(do_fetch)                              -- pcall ensures lock is always released
    os.execute("rmdir " .. lock .. " 2>/dev/null")

    return read_file(FCST_CACHE_FILE)
end

-- Parse the hourly/6-hourly UTC timeseries into daily records shaped
-- exactly like nws_fetch's day_rec
function M.parse_forecast(raw_json)
    local ok, data = pcall(cjson.decode, raw_json)
    if not ok or not data or not data.properties or not data.properties.timeseries then
        return nil, "JSON parse failed or missing timeseries"
    end

    -- cjson decodes JSON null as userdata, not Lua nil; sanitize to nil
    local function nv(v) return type(v) == "number" and v or nil end

    local days, order = {}, {}
    for _, e in ipairs(data.properties.timeseries) do
        local epoch = e.time and iso_to_epoch(e.time)
        if epoch and e.data then
            local date = os.date("%Y-%m-%d", epoch)
            local hour = tonumber(os.date("%H", epoch))
            local day = days[date]
            if not day then
                day = { epoch = epoch, sym_dist = math.huge }
                days[date] = day
                order[#order + 1] = date
            end

            local inst = e.data.instant and e.data.instant.details or {}
            local t = nv(inst.air_temperature)
            if t then
                if not day.t_max or t > day.t_max then day.t_max = t end
                if not day.t_min or t < day.t_min then day.t_min = t end
            end

            -- Representative symbol/wind/pop: sample nearest local midday.
            -- Night-suffixed symbols get a large penalty so a daytime
            -- window always wins when one exists (6-hourly far-out days
            -- can otherwise land on an evening sample)
            local nxt = e.data.next_6_hours or e.data.next_1_hours or e.data.next_12_hours
            local sym = nxt and nxt.summary and nxt.summary.symbol_code
            local dist = math.abs(hour - 12) + (sym and sym:find("_night") and 24 or 0)
            if sym and dist < day.sym_dist then
                day.sym_dist   = dist
                day.symbol     = sym
                day.wind_ms    = nv(inst.wind_speed)
                day.wind_deg   = nv(inst.wind_from_direction)
                -- probability_of_precipitation only exists in some regions
                day.pop        = nxt.details and nv(nxt.details.probability_of_precipitation) or nil
            end
        end
    end

    if #order == 0 then return nil, "No usable timeseries entries" end

    local imperial = (UNITS == "imperial")
    local forecast = {}
    for i = 1, math.min(#order, DAYS_WANTED) do
        local date = order[i]
        local d = days[date]
        if d.t_max then
            local hi, lo = d.t_max, d.t_min
            local wind = d.wind_ms or 0
            if imperial then
                hi   = hi * 9 / 5 + 32
                lo   = lo * 9 / 5 + 32
                wind = wind * 2.23694          -- m/s → mph
            else
                wind = wind * 3.6              -- m/s → km/h
            end
            local sym = d.symbol or "partlycloudy_day"
            local is_day = not sym:find("_night")
            local pop = math.floor((d.pop or 0) + 0.5)
            forecast[#forecast + 1] = {
                date         = date,
                dow          = (i == 1) and "Today" or os.date("%A", d.epoch),
                temp_high    = math.floor(hi + 0.5),
                temp_low     = math.floor(lo + 0.5),
                temp_unit    = imperial and "F" or "C",
                wind_speed   = math.floor(wind + 0.5),
                wind_dir     = compass(d.wind_deg),
                icon         = canonical_from_symbol(sym, is_day),
                icon_url     = "",
                short_fcst   = short_text(sym),
                detail_day   = "",             -- met.no has no forecast prose
                detail_night = "",
                pop_day      = pop,
                pop_night    = pop,
                pop          = pop,
            }
        end
    end

    if #forecast == 0 then return nil, "No complete days in timeseries" end
    return forecast
end

return M
