-- mvtk/combat/hit_reactions.lua
-- Hit reaction system for knockback, stagger, and visual feedback
-- Makes combat feel more impactful with proper reactions to damage

local M = {}

local CombatFeedback = require "mvtk.combat.combat_feedback"

-- Hit reaction types
local REACTION_TYPES = {
    none = {
        knockback_force = 0,
        stagger_duration = 0,
        hitstop_intensity = "light"
    },
    light = {
        knockback_force = 150,
        stagger_duration = 0.1,
        hitstop_intensity = "light",
        shake_intensity = "light"
    },
    medium = {
        knockback_force = 300,
        stagger_duration = 0.2,
        hitstop_intensity = "medium",
        shake_intensity = "medium"
    },
    heavy = {
        knockback_force = 500,
        stagger_duration = 0.35,
        hitstop_intensity = "heavy",
        shake_intensity = "heavy"
    },
    launch = {
        knockback_force = 800,
        knockback_up = 400,
        stagger_duration = 0.5,
        hitstop_intensity = "critical",
        shake_intensity = "critical",
        launch_arc = true
    },
    stun = {
        knockback_force = 100,
        stagger_duration = 1.0,
        hitstop_intensity = "medium",
        shake_intensity = "light",
        stunned = true
    }
}

-- State tracking per entity
local entity_states = {}

function M.get_reaction(reaction_type)
    return REACTION_TYPES[reaction_type] or REACTION_TYPES.medium
end

--- Initialize hit reactions system
function M.init()
    entity_states = {}

    -- Subscribe to room unloads so stale entity_states whose URLs are gone
    -- get swept. entity_states is keyed by entity URL/id (not room id), so
    -- the sweep validates each key with go.exists. Idempotent guard prevents
    -- duplicate subscriptions when init() is called multiple times.
    if not M._room_lifecycle_wired then
        local ok_rm, RoomManager = pcall(require, "mvtk.map.streaming.room_manager")
        if ok_rm and RoomManager and RoomManager.on_room_unload then
            RoomManager.on_room_unload(function(_room_id)
                M.sweep_invalid()
            end)
            M._room_lifecycle_wired = true
        end
    end
end

--- Drop entity_states entries whose entity URL no longer resolves.
-- Safe to call any time; runs in O(n) over current entity_states.
function M.sweep_invalid()
    if not go or not go.exists then return 0 end
    local removed = 0
    for entity_id, _ in pairs(entity_states) do
        local ok, exists = pcall(go.exists, entity_id)
        if not ok or not exists then
            entity_states[entity_id] = nil
            removed = removed + 1
        end
    end
    return removed
end

--- Drop all hit-reaction state. Useful on full game reload / new save load.
function M.clear_all()
    entity_states = {}
end

--- Update hit reactions (call for each entity in their update)
-- @param entity_id Unique entity identifier
-- @param dt Delta time
-- @return Current state table or nil
function M.update(entity_id, dt)
    local state = entity_states[entity_id]
    if not state then
        return nil
    end

    -- Update stagger timer
    if state.stagger_timer > 0 then
        state.stagger_timer = state.stagger_timer - dt

        if state.stagger_timer <= 0 then
            state.is_staggered = false
            state.is_stunned = false
            print(string.format("[HIT_REACTION] Entity %s recovered from stagger", entity_id))
            return "stagger_ended"
        end
    end

    -- Decay knockback velocity
    if state.knockback_velocity then
        state.knockback_velocity = state.knockback_velocity * 0.9

        -- Stop knockback when velocity is negligible
        if vmath.length(state.knockback_velocity) < 10 then
            state.knockback_velocity = nil
        end
    end

    return state
end

--- Apply hit reaction to an entity
-- @param entity_id Unique entity identifier
-- @param reaction_type Type of reaction ("light", "medium", "heavy", "launch", "stun")
-- @param hit_direction Direction vector of the hit
-- @param options Optional table with custom parameters
-- @return Reaction data table
function M.apply_reaction(entity_id, reaction_type, hit_direction, options)
    options = options or {}

    -- Get reaction preset
    local reaction = M.get_reaction(reaction_type)

    -- Initialize entity state if needed
    if not entity_states[entity_id] then
        entity_states[entity_id] = {
            is_staggered = false,
            is_stunned = false,
            stagger_timer = 0,
            knockback_velocity = nil,
            poise_damage = 0
        }
    end

    local state = entity_states[entity_id]

    -- Apply hitstop
    if (not options.skip_hitstop) or (not options.skip_shake) then
        local feedback_kind = "melee"
        if reaction_type == "launch" or reaction_type == "heavy" then
            feedback_kind = "hurt"
        elseif reaction_type == "stun" then
            feedback_kind = "parry"
        end
        CombatFeedback.impact(feedback_kind, options.damage or 1, {
            screen_shake = reaction.shake_intensity,
            hitstop = options.skip_hitstop and 0 or nil,
        })
    end

    -- Calculate knockback
    local knockback_dir = vmath.normalize(hit_direction or vmath.vector3(1, 0, 0))
    local knockback_mult = options.knockback_multiplier or 1.0

    state.knockback_velocity = knockback_dir * reaction.knockback_force * knockback_mult

    -- Add upward force for launch attacks
    if reaction.launch_arc and reaction.knockback_up then
        state.knockback_velocity.y = state.knockback_velocity.y + reaction.knockback_up
    end

    -- Apply stagger
    if reaction.stagger_duration > 0 then
        state.is_staggered = true
        state.stagger_timer = reaction.stagger_duration

        if reaction.stunned then
            state.is_stunned = true
        end
    end

    print(string.format("[HIT_REACTION] Applied '%s' reaction to %s - Knockback: %.1f, Stagger: %.2fs",
        reaction_type, entity_id, reaction.knockback_force, reaction.stagger_duration))

    return {
        reaction_type = reaction_type,
        knockback_velocity = state.knockback_velocity,
        stagger_duration = reaction.stagger_duration,
        is_stunned = reaction.stunned or false,
        entity_id = entity_id
    }
end

--- Check if entity is currently staggered
-- @param entity_id Unique entity identifier
-- @return True if staggered
function M.is_staggered(entity_id)
    local state = entity_states[entity_id]
    return state and state.is_staggered or false
end

--- Check if entity is currently stunned
-- @param entity_id Unique entity identifier
-- @return True if stunned
function M.is_stunned(entity_id)
    local state = entity_states[entity_id]
    return state and state.is_stunned or false
end

--- Get current knockback velocity for entity
-- @param entity_id Unique entity identifier
-- @return Knockback velocity vector or nil
function M.get_knockback_velocity(entity_id)
    local state = entity_states[entity_id]
    return state and state.knockback_velocity or nil
end

--- Cancel hit reaction for entity (useful for super armor)
-- @param entity_id Unique entity identifier
function M.cancel_reaction(entity_id)
    local state = entity_states[entity_id]
    if state then
        state.is_staggered = false
        state.is_stunned = false
        state.stagger_timer = 0
        state.knockback_velocity = nil
        print(string.format("[HIT_REACTION] Cancelled reaction for %s", entity_id))
    end
end

--- Apply poise damage (optional poise system)
-- @param entity_id Unique entity identifier
-- @param poise_damage Amount of poise damage
-- @param poise_threshold Poise threshold before stagger
-- @return True if poise broken (should stagger)
function M.apply_poise_damage(entity_id, poise_damage, poise_threshold)
    if not entity_states[entity_id] then
        entity_states[entity_id] = {
            is_staggered = false,
            is_stunned = false,
            stagger_timer = 0,
            knockback_velocity = nil,
            poise_damage = 0
        }
    end

    local state = entity_states[entity_id]
    state.poise_damage = state.poise_damage + poise_damage

    if state.poise_damage >= poise_threshold then
        state.poise_damage = 0
        print(string.format("[HIT_REACTION] Poise broken for %s", entity_id))
        return true
    end

    return false
end

--- Reset poise damage (call after stagger ends or over time)
-- @param entity_id Unique entity identifier
-- @param amount Amount to reduce (optional, resets to 0 if nil)
function M.reset_poise(entity_id, amount)
    local state = entity_states[entity_id]
    if state then
        if amount then
            state.poise_damage = math.max(0, state.poise_damage - amount)
        else
            state.poise_damage = 0
        end
    end
end

--- Get entity hit reaction state
-- @param entity_id Unique entity identifier
-- @return State table or nil
function M.get_state(entity_id)
    return entity_states[entity_id]
end

--- Remove entity from tracking (call in final())
-- @param entity_id Unique entity identifier
function M.remove_entity(entity_id)
    entity_states[entity_id] = nil
end

--- Create custom reaction type
-- @param name Name for the custom reaction
-- @param params Reaction parameters table
function M.register_custom_reaction(name, params)
    REACTION_TYPES[name] = params
    print(string.format("[HIT_REACTION] Registered custom reaction '%s'", name))
end

--- Get reaction preset
-- @param reaction_type Reaction type name
-- @return Reaction parameters or nil
function M.get_reaction_preset(reaction_type)
    return REACTION_TYPES[reaction_type]
end

return M
