-- mvtk/player/swim_state.lua
-- Swimming state and physics for underwater gameplay
-- Handles different movement mechanics when in water

local M = {}

-- Attempt to load swim settings from developer config
local Util = require "mvtk.core.util"
local SwimConfig = Util.require_config("developer.config.swim_settings")
local Debug = Util.require_config("developer.config.debug_config")
local swim_log = Util.make_debug_log("[SWIM]", function()
    return Debug.global.enable or (Debug.gameplay and Debug.gameplay.swim)
end)

-- Swimming physics constants (configurable via developer/config/swim_settings.lua)
local DEFAULTS = {
    swim_speed = SwimConfig.swim_speed or 200,
    swim_acceleration = SwimConfig.swim_acceleration or 800,
    swim_friction = SwimConfig.swim_friction or 0.85,
    swim_dash_speed = SwimConfig.swim_dash_speed or 400,
    swim_dash_duration = SwimConfig.swim_dash_duration or 0.3,
    bubble_interval = SwimConfig.bubble_interval or 0.5,
    oxygen_max = SwimConfig.oxygen_max or 10.0,
    oxygen_drain_rate = SwimConfig.oxygen_drain_rate or 1.0,
    oxygen_refill_rate = SwimConfig.oxygen_refill_rate or 2.0,
    surface_splash_threshold = SwimConfig.surface_splash_threshold or 50,
    swim_speed_mult = 1.0,
    buoyancy_speed = 0,
    no_swim_sink_speed = nil,
}

local SWIM_SPEED = DEFAULTS.swim_speed
local SWIM_ACCELERATION = DEFAULTS.swim_acceleration
local SWIM_FRICTION = DEFAULTS.swim_friction
local SWIM_DASH_SPEED = DEFAULTS.swim_dash_speed
local SWIM_DASH_DURATION = DEFAULTS.swim_dash_duration
local BUBBLE_INTERVAL = DEFAULTS.bubble_interval
local OXYGEN_MAX = DEFAULTS.oxygen_max
local OXYGEN_DRAIN_RATE = DEFAULTS.oxygen_drain_rate
local OXYGEN_REFILL_RATE = DEFAULTS.oxygen_refill_rate
local SURFACE_SPLASH_THRESHOLD = DEFAULTS.surface_splash_threshold
local SWIM_SPEED_MULT = DEFAULTS.swim_speed_mult
local BUOYANCY_SPEED = DEFAULTS.buoyancy_speed
local NO_SWIM_SINK_SPEED = DEFAULTS.no_swim_sink_speed

-- State
local is_swimming = false
local is_underwater = false
local oxygen = OXYGEN_MAX
local bubble_timer = 0
local dash_timer = 0
local is_dashing = false
local water_surface_y = 0
local current_velocity = vmath.vector3(0, 0, 0)
local swim_direction = vmath.vector3(0, 0, 0)
local water_source = nil
local oxygen_hud_url, oxygen_overlay_url
local oxygen_hud_message, oxygen_overlay_message
local last_oxygen_percent

--- Initialize swimming state
function M.init()
    last_oxygen_percent = nil
    M.reset_params()
    is_swimming = false
    is_underwater = false
    oxygen = OXYGEN_MAX
    bubble_timer = 0
    dash_timer = 0
    is_dashing = false
    current_velocity = vmath.vector3(0, 0, 0)
end

--- Check if player is currently swimming
-- @return True if swimming
function M.is_swimming()
    return is_swimming
end

--- Check if player is underwater (fully submerged)
-- @return True if underwater
function M.is_underwater()
    return is_underwater
end

--- Get current oxygen level (0-1)
-- @return Oxygen percentage
function M.get_oxygen()
    return oxygen / OXYGEN_MAX
end

--- Publish the oxygen ratio only when its displayed whole percentage changes.
-- Cache absolute HUD URLs and message hashes on first use in the runtime host.
function M.publish_oxygen_hud(percent)
    local rounded = math.floor((percent or 0) * 100 + 0.5)
    if rounded == last_oxygen_percent then return end
    if not oxygen_hud_url then
        oxygen_hud_url = msg.url("main:/mode_hud#mode_hud")
        oxygen_overlay_url = msg.url("main:/underwater_overlay#underwater_overlay")
        oxygen_hud_message = hash("hud_oxygen")
        oxygen_overlay_message = hash("oxygen")
    end
    pcall(msg.post, oxygen_hud_url, oxygen_hud_message, { oxygen = percent })
    pcall(msg.post, oxygen_overlay_url, oxygen_overlay_message, { value = rounded })
    last_oxygen_percent = rounded
end

--- Correct the water surface after entry.
-- The bare-trigger entry path has no surface information and falls back to the
-- player's entry Y. A cooperating water volume that reports the real surface a
-- frame later must be able to fix it, since the surface drives is_underwater,
-- oxygen drain and buoyancy.
-- @param surface_y World Y of the water surface
function M.set_surface_y(surface_y)
    local y = tonumber(surface_y)
    if not y then return end
    water_surface_y = y
end

--- Enter water
-- @param surface_y Y position of water surface
-- @param player_y Current player Y position
function M.enter_water(surface_y, player_y, opts)
    opts = opts or {}
    if not is_swimming then
        is_swimming = true
        water_surface_y = surface_y
        water_source = opts.source
        swim_log(string.format("Entered water source=%s surface_y=%.1f", tostring(water_source), surface_y))

        -- Check if fully submerged
        if player_y < surface_y - 20 then  -- Below surface threshold
            is_underwater = true
            swim_log("Player is underwater")
        end

        return "enter_water"  -- Event for splash effect
    end
    return nil
end

--- Exit water
-- @param exit_velocity Velocity when exiting (for splash)
-- @return Event name if should trigger splash
function M.exit_water(exit_velocity)
    last_oxygen_percent = nil
    if is_swimming then
        is_swimming = false
        is_underwater = false
        oxygen = OXYGEN_MAX  -- Refill oxygen instantly on exit

        swim_log(string.format("Exited water source=%s", tostring(water_source)))
        water_source = nil

        -- Check if exit was fast enough for splash
        if exit_velocity and vmath.length(exit_velocity) > SURFACE_SPLASH_THRESHOLD then
            return "exit_water_splash"
        else
            return "exit_water"
        end
    end
    return nil
end

--- Update swimming state
-- @param dt Delta time
-- @param player_pos Current player position
-- @param input Input direction vector
-- @param oxygen_enabled Whether oxygen mechanic is enabled
-- @return Updated velocity vector
function M.update(dt, player_pos, input, oxygen_enabled)
    if not is_swimming then
        return current_velocity
    end

    -- Check if underwater based on position
    local was_underwater = is_underwater
    is_underwater = player_pos.y < water_surface_y - 20

    -- Oxygen management
    if oxygen_enabled then
        if is_underwater then
            oxygen = math.max(0, oxygen - OXYGEN_DRAIN_RATE * dt)

            -- Bubble particles
            bubble_timer = bubble_timer + dt
            if bubble_timer >= BUBBLE_INTERVAL then
                bubble_timer = 0
                -- Trigger bubble particle effect
                -- This should be handled by the caller
            end

            if oxygen <= 0 then
                -- Player is drowning - take damage
                return current_velocity, "drowning"
            end
        else
            -- At surface - refill oxygen
            oxygen = math.min(OXYGEN_MAX, oxygen + OXYGEN_REFILL_RATE * dt)
        end
    end

    -- Swimming dash
    if is_dashing then
        dash_timer = dash_timer - dt
        if dash_timer <= 0 then
            is_dashing = false
        end
        -- Dash maintains constant velocity
        return current_velocity
    end

    -- Normal swimming physics
    swim_direction.x = input.x
    swim_direction.y = input.y
    swim_direction.z = 0

    -- Normalize if diagonal
    local mag = vmath.length(swim_direction)
    if mag > 1.0 then
        swim_direction = swim_direction / mag
    end

    -- Time-independent acceleration reaches the configured target regardless
    -- of frame rate. Drift damping applies only when the player is not steering.
    local target_x = swim_direction.x * SWIM_SPEED * SWIM_SPEED_MULT
    local target_y = swim_direction.y * SWIM_SPEED * SWIM_SPEED_MULT
    local rate = 1 - math.exp(-(SWIM_ACCELERATION / math.max(1, SWIM_SPEED)) * dt)
    current_velocity.x = current_velocity.x + (target_x - current_velocity.x) * rate
    current_velocity.y = current_velocity.y + (target_y - current_velocity.y) * rate

    local damp = math.pow(SWIM_FRICTION, dt * 60)
    if math.abs(swim_direction.x) < 0.01 then current_velocity.x = current_velocity.x * damp end
    if math.abs(swim_direction.y) < 0.01 then current_velocity.y = current_velocity.y * damp end

    -- Per-volume buoyancy is in px/s and only assists a player who is not
    -- intentionally steering vertically below the surface.
    if BUOYANCY_SPEED > 0 and math.abs(swim_direction.y) < 0.01
        and player_pos.y < (water_surface_y - 4) then
        current_velocity.y = current_velocity.y + BUOYANCY_SPEED * dt
        current_velocity.y = math.min(current_velocity.y, BUOYANCY_SPEED)
    end

    -- Surface effect - harder to go down at surface
    if not is_underwater and player_pos.y >= water_surface_y - 10 then
        if current_velocity.y < -50 then
            current_velocity.y = current_velocity.y * 0.5  -- Resist going down
        end
    end

    return current_velocity
end

--- Trigger underwater dash
-- @param direction Direction vector
-- @return True if dash was triggered
function M.dash(direction)
    if not is_swimming or is_dashing then
        return false
    end

    local dash_dir = vmath.normalize(direction)
    current_velocity = dash_dir * SWIM_DASH_SPEED
    is_dashing = true
    dash_timer = SWIM_DASH_DURATION

    swim_log("Underwater dash")
    return true
end

--- Check if can perform underwater dash
-- @return True if can dash
function M.can_dash()
    return is_swimming and not is_dashing
end

--- Get swimming stats for UI/debugging
-- @return Stats table
function M.get_stats()
    return {
        is_swimming = is_swimming,
        is_underwater = is_underwater,
        oxygen = oxygen,
        oxygen_percent = oxygen / OXYGEN_MAX,
        is_dashing = is_dashing,
        velocity = current_velocity,
        speed = vmath.length(current_velocity),
        swim_speed = SWIM_SPEED,
        swim_speed_mult = SWIM_SPEED_MULT,
        buoyancy_speed = BUOYANCY_SPEED,
        source = water_source,
    }
end

--- Set swimming physics parameters
-- @param params Table of parameters to override
function M.set_params(params)
    if type(params) ~= "table" then return end
    if params.swim_speed then SWIM_SPEED = params.swim_speed end
    if params.swim_acceleration then SWIM_ACCELERATION = params.swim_acceleration end
    if params.swim_friction then SWIM_FRICTION = params.swim_friction end
    if params.swim_dash_speed then SWIM_DASH_SPEED = params.swim_dash_speed end
    if params.swim_dash_duration then SWIM_DASH_DURATION = params.swim_dash_duration end
    if params.oxygen_max then
        OXYGEN_MAX = params.oxygen_max
        oxygen = OXYGEN_MAX
    end
    if params.oxygen_drain_rate then OXYGEN_DRAIN_RATE = params.oxygen_drain_rate end
    if params.oxygen_refill_rate then OXYGEN_REFILL_RATE = params.oxygen_refill_rate end
    if params.swim_speed_mult ~= nil then SWIM_SPEED_MULT = math.max(0, tonumber(params.swim_speed_mult) or 1.0) end
    -- Water-volume drag is authored as retention per second. Convert it to
    -- the internal 60 Hz reference value used by the dt-independent damping.
    if params.water_drag ~= nil then
        local retention = math.max(0, math.min(1, tonumber(params.water_drag) or 1.0))
        SWIM_FRICTION = math.pow(retention, 1 / 60)
    end
    if params.buoyancy_speed ~= nil then BUOYANCY_SPEED = math.max(0, tonumber(params.buoyancy_speed) or 0) end
    if params.no_swim_sink_speed ~= nil then NO_SWIM_SINK_SPEED = tonumber(params.no_swim_sink_speed) end
end

--- Restore all authored developer/config/swim_settings.lua defaults.
function M.reset_params()
    SWIM_SPEED = DEFAULTS.swim_speed
    SWIM_ACCELERATION = DEFAULTS.swim_acceleration
    SWIM_FRICTION = DEFAULTS.swim_friction
    SWIM_DASH_SPEED = DEFAULTS.swim_dash_speed
    SWIM_DASH_DURATION = DEFAULTS.swim_dash_duration
    BUBBLE_INTERVAL = DEFAULTS.bubble_interval
    OXYGEN_MAX = DEFAULTS.oxygen_max
    OXYGEN_DRAIN_RATE = DEFAULTS.oxygen_drain_rate
    OXYGEN_REFILL_RATE = DEFAULTS.oxygen_refill_rate
    SURFACE_SPLASH_THRESHOLD = DEFAULTS.surface_splash_threshold
    SWIM_SPEED_MULT = DEFAULTS.swim_speed_mult
    BUOYANCY_SPEED = DEFAULTS.buoyancy_speed
    NO_SWIM_SINK_SPEED = DEFAULTS.no_swim_sink_speed
    oxygen = math.min(oxygen, OXYGEN_MAX)
end

--- Force set oxygen level
-- @param amount Oxygen amount (0 to OXYGEN_MAX)
function M.set_oxygen(amount)
    oxygen = math.max(0, math.min(OXYGEN_MAX, amount))
end

--- Reset velocity (useful for state transitions)
function M.reset_velocity()
    current_velocity = vmath.vector3(0, 0, 0)
end

--- Check if should generate bubbles this frame
-- @return True if should spawn bubble particle
function M.should_spawn_bubble()
    return is_underwater and bubble_timer == 0
end

return M
