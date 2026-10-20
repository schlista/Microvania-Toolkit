-- Pure camera smoothing and render quantization helpers.

local M = {}

local MAX_CAMERA_DT = 1 / 30

function M.clamp_dt(dt)
    return math.min(math.max(0, tonumber(dt) or 0), MAX_CAMERA_DT)
end

function M.exponential_alpha(speed, dt)
    local k = math.max(0, tonumber(speed) or 0)
    return 1 - math.exp(-k * M.clamp_dt(dt))
end

function M.deadzone_step(current, target, deadzone, speed, dt, scale, previous_target)
    local from = tonumber(current) or 0
    local to = tonumber(target) or from
    local zone = math.max(0, tonumber(deadzone) or 0)
    local weight = math.max(0, math.min(1, tonumber(scale) or 1))
    local delta = to - from
    if math.abs(delta) <= zone or weight <= 0 then
        return from
    end
    local sign = delta < 0 and -1 or 1
    local step_dt = M.clamp_dt(dt)
    local k = math.max(0, tonumber(speed) or 0)
    local previous = tonumber(previous_target)
    -- Integrate the target's motion across this frame, rather than pretending
    -- its final position was stationary for the whole frame. The latter has
    -- a dt-dependent trailing distance and visibly kicks when a refresh is
    -- missed, even when the target runs at perfectly constant velocity.
    -- Keep the stationary response on first acquisition, inside a previous
    -- deadzone, or while zone locks blend the follow weight.
    if previous and weight == 1 and step_dt > 0 and k * step_dt > 0.000001
        and (previous - from) * sign >= zone then
        local velocity = (to - previous) / step_dt
        local edge = to - sign * zone
        local previous_edge = previous - sign * zone
        local lag = velocity / k
        local next_position = edge - lag + (from - previous_edge + lag) * math.exp(-k * step_dt)
        -- Reversals must not continue away from the new target or cross its
        -- deadzone. Teleports reset target history in camera.script.
        return math.max(math.min(from, edge), math.min(math.max(from, edge), next_position))
    end
    return from + (delta - sign * zone) * M.exponential_alpha(speed, dt) * weight
end

-- Input supplies direction, never the camera/target error. A resting camera
-- therefore cannot flip its own look-ahead and oscillate around the player.
function M.lookahead(current, direction, distance, speed, dt)
    local desired=math.max(-1,math.min(1,tonumber(direction) or 0))*(tonumber(distance) or 0)
    return (current or 0)+(desired-(current or 0))*M.exponential_alpha(speed,dt)
end

function M.round_to_screen_pixel(value, zoom)
    local z = math.max(0.0001, tonumber(zoom) or 1)
    return math.floor((tonumber(value) or 0) * z + 0.5) / z
end

function M.render_xy(x, y, zoom, pixel_snap)
    if pixel_snap == false then
        return tonumber(x) or 0, tonumber(y) or 0
    end
    return M.round_to_screen_pixel(x, zoom), M.round_to_screen_pixel(y, zoom)
end

return M
