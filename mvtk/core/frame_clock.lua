-- Frame clock: preserves elapsed time by default; optional experimental snap.
--
-- With display.update_frequency = 0 Defold supplies measured frame time.
-- Motion must normally use that time: a genuinely late frame needs a larger
-- displacement to preserve speed. Bosses, engine timers and flipbooks use
-- the engine clock too.
--
-- When explicitly enabled, snap(raw_dt) maps dt near a known refresh
-- interval onto that interval exactly. Anything else (a real hitch, an
-- unusual display, a frame the engine already capped) passes through
-- unchanged. It is a pure function of its input: same raw dt in, same value
-- out, no per-frame state, so the order in which scripts update never
-- matters and no frame-boundary detection is needed.
--
-- A snapped frame can be re-timed by up to TOLERANCE, creating drift relative
-- to engine-driven animation and timers (about 0.1% on a 59.94 Hz display).
--
-- A single sample cannot distinguish measurement noise from a late frame.
-- Snapping is therefore opt-in: Config.performance.dt_snap = true.

local M = {}

-- Common display refresh intervals, in seconds.
M.INTERVALS = {
    1 / 60,
    1 / 75,
    1 / 90,
    1 / 100,
    1 / 120,
    1 / 144,
    1 / 165,
    1 / 240,
}

-- Relative distance from an interval within which a dt snaps to it.
--
-- 3% is ~0.5 ms at 60 Hz. Even this narrow window can absorb real timing
-- variation; it is an experimental tolerance, not a late-frame detector.
M.TOLERANCE = 0.03

-- At or above this the frame is a genuine hitch (engine.max_time_step default
-- is 1/30); never rewrite it.
M.MAX_SNAP_DT = 1 / 30

local enabled_override = nil

local function config_enabled()
    local ok, Config = pcall(require, "developer.config.resolved_config")
    if not ok or type(Config) ~= "table" then
        return false
    end
    local performance = Config.performance
    if type(performance) ~= "table" then
        return false
    end
    return performance.dt_snap == true
end

--- Force snapping on/off (tests, tools). Pass nil to follow the config again.
function M.set_enabled(value)
    if value == nil then
        enabled_override = nil
    else
        enabled_override = value and true or false
    end
end

function M.is_enabled()
    if enabled_override ~= nil then
        return enabled_override
    end
    return config_enabled()
end

--- The refresh interval `raw_dt` is within tolerance of, or nil.
-- Pure; ignores the enabled flag.
function M.snap_interval(raw_dt)
    local dt = tonumber(raw_dt) or 0
    if dt <= 0 or dt >= M.MAX_SNAP_DT then
        return nil
    end
    local best, best_error = nil, nil
    for i = 1, #M.INTERVALS do
        local interval = M.INTERVALS[i]
        local relative_error = math.abs(dt - interval) / interval
        if relative_error <= M.TOLERANCE and (best_error == nil or relative_error < best_error) then
            best, best_error = interval, relative_error
        end
    end
    return best
end

--- Regularised dt for simulation. Pure apart from the config/override flag.
function M.snap(raw_dt)
    local dt = tonumber(raw_dt) or 0
    if dt <= 0 then
        return 0
    end
    if not M.is_enabled() then
        return dt
    end
    return M.snap_interval(dt) or dt
end

return M
