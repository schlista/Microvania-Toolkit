-- Pure predicate/math for the contact-based ceiling safety net.

local M = {}

function M.evaluate(message, cfg, state, deps)
    cfg = cfg or {}
    state = state or {}
    deps = deps or {}
    local group = message and message.other_group
    if cfg.ceiling_response == false
        or not group
        or not deps.is_terrain_group
        or not deps.is_terrain_group(group)
        or group == deps.platform_group
        or not message.normal
        or message.distance == nil
        or (tonumber(message.normal.y) or 0) > -(tonumber(cfg.angle_threshold) or 0.7)
        or (tonumber(message.distance) or 0) <= (tonumber(cfg.penetration_threshold) or 1.0)
        or (tonumber(state.vy) or 0) < 0
        or (tonumber(state.bypass_ceiling_frames) or 0) > 0
        -- The raycast solver consumes the frame counter before physics
        -- contacts arrive. Ladder intent lasts the whole climb frame, but a
        -- dismount/water entry must not inherit a previous frame's intent.
        or (state._in_climb and not state._in_water and state._climb_top_pass_active == true) then
        return nil
    end

    local correction = (tonumber(message.distance) or 0)
        + (tonumber(cfg.penetration_safety_margin) or 0.1)
    return {
        correction = correction,
        delta_y = (tonumber(message.normal.y) or 0) * correction,
        stop_upward_velocity = (tonumber(state.vy) or 0) > 0,
    }
end

return M
