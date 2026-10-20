-- Apply current unlocks to the player's configured movement values. These
-- switches follow the live registry; tuning survives start, pickup and restore.
local M = {}

function M.apply(overrides, base, is_unlocked, is_defined, log)
    base = base or {}
    log = log or function() end
    log(">>> APPLY_ABILITY_STATES CALLED <<<")

    if is_unlocked("double_jump", true) then
        -- Preserve the legacy zero-count fallback when Double Jump is unlocked.
        overrides.air_jumps = (base.air_jumps and base.air_jumps > 0) and base.air_jumps or 1
    else
        overrides.air_jumps = 0
    end

    for _, id in ipairs({ "slide", "air_dash" }) do
        local config = overrides[id]
        if config then
            config.enabled = is_unlocked(id, true)
            local iframe_id = id .. "_iframes"
            if is_defined(iframe_id) then
                -- Invincibility is itself an ability, so a false baseline must
                -- never prevent a later pickup from granting it.
                config.iframes = is_unlocked(iframe_id, true) and true or false
            elseif base[iframe_id] ~= nil then
                config.iframes = base[iframe_id]
            end
        end
    end

    if overrides.slide_to_run then
        overrides.slide_to_run.enabled = is_unlocked("dash", true)
    end

    if overrides.wall_climb then
        local config = overrides.wall_climb
        local climb_unlocked = is_unlocked("wall_climb", true)
        config.enabled = climb_unlocked
        config.wall_jump = config.wall_jump or {}
        local jump_unlocked = is_defined("wall_jump") and is_unlocked("wall_jump", true) or climb_unlocked
        config.wall_jump.enabled = jump_unlocked and true or false
        if config.wall_jump.input_allow_neutral == nil then
            config.wall_jump.input_allow_neutral = true
        end
    end

    if overrides.extended_jump then
        overrides.extended_jump.enabled = is_unlocked("extended_jump", true)
    end

    if overrides.glide then
        local config = overrides.glide
        config.enabled = is_unlocked("glide", true)
        if config.require_jump_held == nil then config.require_jump_held = true end
        if config.gravity_mult == nil then config.gravity_mult = 0.22 end
        if config.max_fall_speed == nil then config.max_fall_speed = 900 end
    end

    if overrides.ground_pound then
        overrides.ground_pound.enabled = is_unlocked("ground_pound", true)
    end

    log(string.format(">>> FINAL: air_jumps=%s slide=%s air_dash=%s wall_climb=%s wall_jump=%s glide=%s ground_pound=%s",
        tostring(overrides.air_jumps),
        overrides.slide and tostring(overrides.slide.enabled) or "nil",
        overrides.air_dash and tostring(overrides.air_dash.enabled) or "nil",
        overrides.wall_climb and tostring(overrides.wall_climb.enabled) or "nil",
        overrides.wall_climb and overrides.wall_climb.wall_jump and tostring(overrides.wall_climb.wall_jump.enabled) or "nil",
        overrides.glide and tostring(overrides.glide.enabled) or "nil",
        overrides.ground_pound and tostring(overrides.ground_pound.enabled) or "nil"))
end

return M
