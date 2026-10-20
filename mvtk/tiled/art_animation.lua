-- Tiled frame durations stay authoritative; no fixed-FPS rounding or drift.
local M = {}
function M.duration(frames)
    local total = 0
    for _, frame in ipairs(frames or {}) do total = total + frame.duration end
    return total
end
function M.sample(frames, time)
    local total = M.duration(frames)
    if total <= 0 then return nil end
    local elapsed = math.max(0, tonumber(time) or 0) % total
    for index, frame in ipairs(frames) do
        if elapsed < frame.duration then return frame, index end
        elapsed = elapsed - frame.duration
    end
    return frames[1], 1
end
function M.hazard_start(frames, active)
    local offset = 0
    for _, frame in ipairs(frames or {}) do
        if frame.hazard_active == active then return offset end
        offset = offset + frame.duration
    end
    return 0
end
return M
