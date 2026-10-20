-- mvtk/enemies/enemy_locomotion.lua
-- Pure helper for selecting logical locomotion animation states.

local M = {}

local function has_state(states, state)
    return type(states) == "table" and states[state] ~= nil and states[state] ~= false
end

local STATE_FALLBACKS = {
    idle = { "fly_idle" },
    walk = { "run", "fly", "idle" },
    run = { "walk", "fly", "idle" },
    jump = { "attack", "charge", "walk", "fly", "idle" },
    fall = { "jump", "walk", "fly", "idle" },
    attack = { "charge", "ranged_attack", "idle" },
    ranged_attack = { "attack", "charge", "idle" },
    hurt = { "idle" },
    death = { "hurt", "idle" },
    aim = { "ranged_attack", "attack", "idle" },
    charge = { "attack", "walk", "idle" },
}

function M.resolve_state(skin_states, requested_state)
    requested_state = type(requested_state) == "string" and requested_state or nil
    if not requested_state or requested_state == "" then
        return nil
    end
    if type(skin_states) ~= "table" then
        return requested_state
    end
    if has_state(skin_states, requested_state) then
        return requested_state
    end

    for _, candidate in ipairs(STATE_FALLBACKS[requested_state] or {}) do
        if has_state(skin_states, candidate) then
            return candidate
        end
    end

    if has_state(skin_states, "idle") then
        return "idle"
    end
    return nil
end

function M.compute_profile(skin_states, uses_run_animation)
    if type(skin_states) ~= "table" then
        return {
            move = uses_run_animation and "run" or "walk",
            idle = "idle",
        }
    end

    if has_state(skin_states, "fly") and not has_state(skin_states, "walk") then
        return {
            move = "fly",
            idle = has_state(skin_states, "fly_idle") and "fly_idle" or "idle",
        }
    end

    if has_state(skin_states, "run") and uses_run_animation then
        return { move = "run", idle = "idle" }
    end

    if has_state(skin_states, "walk") then
        return { move = "walk", idle = "idle" }
    end

    if has_state(skin_states, "fly") then
        return {
            move = "fly",
            idle = has_state(skin_states, "fly_idle") and "fly_idle" or "idle",
        }
    end

    return { move = "idle", idle = "idle" }
end

return M
