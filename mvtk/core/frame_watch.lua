-- Lightweight frame instrumentation. Disabled by default.
--
-- Two outputs, both gated by Debug.perf.frame_watch (or Debug.global.enable):
--   * one line per hitch (dt above the threshold) with room load/unload counts;
--   * one summary line per second with the dt distribution, so judder (uneven
--     frame times at a steady frame rate) is measurable, not just visible.
--
-- The steady path allocates nothing: samples live in a reused array and the
-- summary sorts a reused scratch array once per window.

local Debug = require "developer.config.debug_config"

local M = {}

local MAX_SAMPLES = 1024

local threshold = 0.033
local summary_interval = 1.0
local room_id = nil
local loads_this_frame = 0
local unloads_this_frame = 0

local window_time = 0
local window_frames = 0
local window_hitches = 0
local window_sum = 0
local window_min = math.huge
local window_max = 0
local samples = {}
local scratch = {}
local lua_kb_at_window_start = nil
local last_summary = nil

local function enabled()
    return (Debug.global and Debug.global.enable)
        or (Debug.perf and Debug.perf.frame_watch)
end

local function lua_kb()
    if type(collectgarbage) ~= "function" then return nil end
    local ok, value = pcall(collectgarbage, "count")
    if ok and type(value) == "number" then return value end
    return nil
end

local function reset_window()
    window_time = 0
    window_frames = 0
    window_hitches = 0
    window_sum = 0
    window_min = math.huge
    window_max = 0
    lua_kb_at_window_start = lua_kb()
end

local function summarize()
    local n = window_frames
    if n <= 0 then return nil end

    local count = math.min(n, MAX_SAMPLES)
    for i = 1, count do
        scratch[i] = samples[i]
    end
    for i = #scratch, count + 1, -1 do
        scratch[i] = nil
    end
    table.sort(scratch)

    local median
    if count % 2 == 1 then
        median = scratch[(count + 1) / 2]
    else
        median = (scratch[count / 2] + scratch[count / 2 + 1]) * 0.5
    end

    local off_median = 0
    local tolerance = median * 0.10
    for i = 1, count do
        if math.abs(scratch[i] - median) > tolerance then
            off_median = off_median + 1
        end
    end

    local kb_now = lua_kb()
    local kb_delta = nil
    if kb_now and lua_kb_at_window_start then
        kb_delta = kb_now - lua_kb_at_window_start
    end

    last_summary = {
        seconds = window_time,
        frames = n,
        mean = window_sum / n,
        median = median,
        min = window_min,
        max = window_max,
        off_median = off_median,
        hitches = window_hitches,
        lua_kb_delta = kb_delta,
        room = room_id,
    }
    return last_summary
end

function M.set_threshold(seconds)
    local value = tonumber(seconds)
    if value and value > 0 then
        threshold = value
    end
end

--- Seconds of frames folded into each summary line (default 1.0).
function M.set_summary_interval(seconds)
    local value = tonumber(seconds)
    if value and value > 0 then
        summary_interval = value
    end
end

function M.set_room(id)
    room_id = id
end

function M.record_load()
    loads_this_frame = loads_this_frame + 1
end

function M.record_unload()
    unloads_this_frame = unloads_this_frame + 1
end

--- The most recent per-window summary table, or nil (tests, overlays).
function M.get_last_summary()
    return last_summary
end

--- Drop accumulated window state (tests).
function M.reset()
    reset_window()
    lua_kb_at_window_start = nil
    last_summary = nil
end

function M.update(dt)
    local frame_dt = math.max(0, tonumber(dt) or 0)
    if not enabled() then
        loads_this_frame = 0
        unloads_this_frame = 0
        return
    end

    if frame_dt > threshold then
        window_hitches = window_hitches + 1
        print(string.format(
            "[FRAME_WATCH] hitch dt=%.2fms room=%s loads_this_frame=%d unloads_this_frame=%d",
            frame_dt * 1000,
            tostring(room_id or "none"),
            loads_this_frame,
            unloads_this_frame))
    end

    if lua_kb_at_window_start == nil then
        lua_kb_at_window_start = lua_kb()
    end
    window_frames = window_frames + 1
    if window_frames <= MAX_SAMPLES then
        samples[window_frames] = frame_dt
    end
    window_time = window_time + frame_dt
    window_sum = window_sum + frame_dt
    if frame_dt < window_min then window_min = frame_dt end
    if frame_dt > window_max then window_max = frame_dt end

    if window_time >= summary_interval then
        local s = summarize()
        if s then
            print(string.format(
                "[FRAME_WATCH] %.1fs frames=%d fps=%.1f dt_ms mean=%.2f median=%.2f min=%.2f max=%.2f off_median>10%%=%d hitches=%d lua_kb_delta=%s room=%s",
                s.seconds,
                s.frames,
                s.frames / math.max(s.seconds, 0.0001),
                s.mean * 1000,
                s.median * 1000,
                s.min * 1000,
                s.max * 1000,
                s.off_median,
                s.hitches,
                s.lua_kb_delta and string.format("%.0f", s.lua_kb_delta) or "n/a",
                tostring(room_id or "none")))
        end
        reset_window()
    end

    loads_this_frame = 0
    unloads_this_frame = 0
end

return M
