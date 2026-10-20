------------------------------------------------------------------------
-- mvtk/camera/camera_zones.lua
-- Camera zone system for per-room camera behavior.
-- Allows different camera settings for different areas.
--
-- HOW IT WORKS
-- ============
-- Each room can be assigned a "camera zone" that overrides the default
-- camera behaviour from game_config.lua.  Zones are either one of the
-- built-in presets below, or a custom table you create with
-- M.create_custom_zone().
--
-- FIELD REFERENCE (each preset contains these fields)
-- ===================================================
--   deadzone          (vector3) Pixels the player can move before the
--                     camera starts following.  x = horizontal, y = vertical.
--                     Larger values = looser / more "floaty" feel.
--
--   speed             (vector3) Camera follow-speed multiplier.
--                     Higher = snappier.  Lower = more cinematic lag.
--
--   lookahead         (number)  Pixels the camera shifts ahead of the
--                     player's movement direction.  0 = disabled.
--
--   bounds_padding    (number)  Extra padding inside room edges so
--                     the camera doesn't push right against walls.
--
--   allow_look_around (bool)    When true the player can hold up/down
--                     to peek vertically beyond the deadzone.
--
--   smooth_transition (bool)    When true, blends smoothly when
--                     switching between zones.  False = instant snap.
--
--   lock_camera       (bool)    When true, camera ignores player
--                     movement entirely (boss arenas, cutscenes).
--
--   clamp_to_room     (bool)    When true, the follow camera keeps its
--                     view inside the current room's rectangle (inset by
--                     bounds_padding) instead of showing past the room's
--                     edges. Rooms smaller than the view stay centred.
--                     Defaults to false.
--
-- USAGE (from room loader or Tiled properties)
-- =============================================
--   local CZ = require("mvtk.camera.camera_zones")
--   CZ.register_zone("room_3b", "boss_arena")   -- use a preset
--   CZ.activate_zone("room_3b")                 -- switch to it
--
-- AVAILABLE PRESETS
-- =================
--   "exploration"     Default open-area tracking; follow fields inherit the
--                     project camera config (see M.set_project_defaults)
--   "boss_arena"      Locked camera for boss fights
--   "platforming"     Tight, responsive tracking for precision sections
--   "cutscene"        Slow cinematic movement, loose deadzone
--   "tight_corridor"  Very tight tracking for narrow passages
------------------------------------------------------------------------

local M = {}

-- Fallback follow values for the default "exploration" zone, used only until
-- the camera injects the project configuration via M.set_project_defaults().
-- The exploration zone is the merge base for every custom zone, so after
-- injection an unauthored field always resolves to the project configuration
-- and only explicitly authored zone fields override it.
local EXPLORATION_FALLBACK = {
    deadzone_x = 50, deadzone_y = 30,
    speed_x = 6.5, speed_y = 6.5,
    lookahead = 180,
}

-- Zone types with default settings
local ZONE_PRESETS = {
    exploration = {
        deadzone = vmath.vector3(EXPLORATION_FALLBACK.deadzone_x, EXPLORATION_FALLBACK.deadzone_y, 0),
        speed = vmath.vector3(EXPLORATION_FALLBACK.speed_x, EXPLORATION_FALLBACK.speed_y, 0),
        lookahead = EXPLORATION_FALLBACK.lookahead,
        bounds_padding = 50,
        allow_look_around = true,
        smooth_transition = true
    },
    boss_arena = {
        deadzone = vmath.vector3(200, 150, 0),  -- Tighter deadzone
        speed = vmath.vector3(8.0, 8.0, 0),     -- Faster tracking
        lookahead = 0,                           -- No lookahead
        bounds_padding = 0,                      -- Tight to arena
        allow_look_around = false,               -- No manual camera control
        smooth_transition = false,               -- Snap to position
        lock_camera = true,                      -- Completely lock camera
        auto_fit = true                          -- Auto zoom-out to keep full arena in view
    },
    platforming = {
        deadzone = vmath.vector3(45, 35, 0),    -- Tight tracking for precision
        speed = vmath.vector3(7.0, 7.5, 0),     -- Very responsive (Shinobi feel)
        lookahead = 180,                        -- Match exploration for consistency
        bounds_padding = 50,
        allow_look_around = true,
        smooth_transition = true
    },
    cutscene = {
        deadzone = vmath.vector3(1000, 1000, 0), -- Very loose
        speed = vmath.vector3(2.0, 2.0, 0),      -- Slow cinematic movement
        lookahead = 0,
        bounds_padding = 100,
        allow_look_around = false,
        smooth_transition = true,
        lock_camera = false
    },
    tight_corridor = {
        deadzone = vmath.vector3(40, 20, 0),    -- Very tight
        speed = vmath.vector3(6.0, 6.0, 0),     -- Fast response
        lookahead = 80,
        bounds_padding = 20,
        allow_look_around = true,
        smooth_transition = true
    }
}

-- State
local current_zone = nil
local previous_zone = nil
local zones_by_room = {}
local transition_active = false
local transition_time = 0
local transition_duration = 0.5
local lerped_settings = {}

--- Initialize camera zones system
-- Project defaults injected via M.set_project_defaults() survive init();
-- init() only resets zone registrations and transition state.
function M.init()
    current_zone = ZONE_PRESETS.exploration
    previous_zone = nil
    zones_by_room = {}
    transition_active = false
    transition_time = 0
end

--- Inject the project camera configuration as the default follow behaviour.
-- Rebuilds the "exploration" preset in place (live references keep working)
-- so the default zone — and every custom zone's unauthored fields — inherit
-- the project configuration instead of hardcoded preset values.
-- @param defaults { deadzone = {x,y}, speed = {x,y}, lookahead = number };
--        pass nil to restore the built-in fallback values.
function M.set_project_defaults(defaults)
    -- Accept plain tables and vmath.vector3 (userdata in the engine) alike.
    local function xy_source(value)
        local t = type(value)
        if t == "table" or t == "userdata" then return value end
        return {}
    end
    local d = type(defaults) == "table" and defaults or {}
    local dz = xy_source(d.deadzone)
    local sp = xy_source(d.speed)
    local exploration = ZONE_PRESETS.exploration
    exploration.deadzone = vmath.vector3(
        tonumber(dz.x) or EXPLORATION_FALLBACK.deadzone_x,
        tonumber(dz.y) or EXPLORATION_FALLBACK.deadzone_y,
        0)
    exploration.speed = vmath.vector3(
        tonumber(sp.x) or EXPLORATION_FALLBACK.speed_x,
        tonumber(sp.y) or EXPLORATION_FALLBACK.speed_y,
        0)
    exploration.lookahead = tonumber(d.lookahead) or EXPLORATION_FALLBACK.lookahead
end

--- Register a camera zone for a specific room
-- @param room_id Room identifier
-- @param zone_type Preset type or custom settings table
function M.register_zone(room_id, zone_type)
    local zone_settings

    if type(zone_type) == "string" then
        zone_settings = ZONE_PRESETS[zone_type]
        if not zone_settings then
            print(string.format("[CAMERA_ZONES] Warning: Unknown preset '%s', using exploration", zone_type))
            zone_settings = ZONE_PRESETS.exploration
        end
    elseif type(zone_type) == "table" then
        -- Custom settings, merge with exploration defaults
        zone_settings = {}
        for k, v in pairs(ZONE_PRESETS.exploration) do
            zone_settings[k] = v
        end
        for k, v in pairs(zone_type) do
            zone_settings[k] = v
        end
    else
        zone_settings = ZONE_PRESETS.exploration
    end

    zones_by_room[room_id] = zone_settings
    print(string.format("[CAMERA_ZONES] Registered zone for room '%s'", room_id))
end

--- Read a room's registered settings without activating or changing its zone.
function M.get_registered_zone(room_id)
    return zones_by_room[room_id]
end

--- Activate a camera zone (called when entering a room)
-- @param room_id Room identifier
-- @param instant Skip smooth transition if true
function M.activate_zone(room_id, instant)
    local zone_settings = zones_by_room[room_id] or ZONE_PRESETS.exploration

    if zone_settings == current_zone then
        return  -- Already in this zone
    end

    previous_zone = current_zone
    current_zone = zone_settings

    if instant or not zone_settings.smooth_transition then
        transition_active = false
        transition_time = 0
        print(string.format("[CAMERA_ZONES] Instantly activated zone for room '%s'", room_id))
    else
        transition_active = true
        transition_time = 0
        print(string.format("[CAMERA_ZONES] Transitioning to zone for room '%s'", room_id))
    end
end

--- Update camera zone transitions
-- @param dt Delta time
function M.update(dt)
    if not transition_active then
        return
    end

    transition_time = transition_time + dt

    if transition_time >= transition_duration then
        transition_active = false
        transition_time = 0
        previous_zone = nil
    end
end

--- Get current camera settings (with smooth transition if active)
-- @return Settings table
function M.get_settings()
    if not transition_active or not previous_zone then
        return current_zone
    end

    -- Lerp between previous and current zone settings
    local t = math.min(1.0, transition_time / transition_duration)
    t = t * t * (3 - 2 * t)  -- Smoothstep

    lerped_settings.deadzone = vmath.lerp(t, previous_zone.deadzone, current_zone.deadzone)
    lerped_settings.speed = vmath.lerp(t, previous_zone.speed, current_zone.speed)
    lerped_settings.lookahead = previous_zone.lookahead + (current_zone.lookahead - previous_zone.lookahead) * t
    lerped_settings.bounds_padding = previous_zone.bounds_padding + (current_zone.bounds_padding - previous_zone.bounds_padding) * t
    lerped_settings.allow_look_around = current_zone.allow_look_around
    lerped_settings.lock_camera = current_zone.lock_camera
    lerped_settings.lock_x = current_zone.lock_x
    lerped_settings.lock_y = current_zone.lock_y
    lerped_settings.focus_x = current_zone.focus_x
    lerped_settings.focus_y = current_zone.focus_y
    lerped_settings.zoom_level = current_zone.zoom_level
    lerped_settings.clamp_to_room = current_zone.clamp_to_room

    return lerped_settings
end

--- Check if camera should be locked (no player movement tracking)
-- @return True if camera is locked
function M.is_locked()
    return current_zone and current_zone.lock_camera or false
end

--- Check if manual look-around is allowed
-- @return True if allowed
function M.allow_look_around()
    return current_zone and current_zone.allow_look_around or true
end

--- Get a preset zone
-- @param preset_name Preset name
-- @return Zone settings table
function M.get_preset(preset_name)
    return ZONE_PRESETS[preset_name]
end

--- Create a custom zone by merging preset with overrides
-- @param base_preset Base preset name
-- @param overrides Table of settings to override
-- @return Zone settings table
function M.create_custom_zone(base_preset, overrides)
    local base = ZONE_PRESETS[base_preset] or ZONE_PRESETS.exploration
    local custom = {}

    for k, v in pairs(base) do
        custom[k] = v
    end

    if overrides then
        for k, v in pairs(overrides) do
            custom[k] = v
        end
    end

    return custom
end

--- Set transition duration
-- @param duration Duration in seconds
function M.set_transition_duration(duration)
    local value = tonumber(duration)
    if not value then
        return
    end
    if value < 0 then
        value = 0
    end
    transition_duration = value
end

--- Force immediate transition completion
function M.complete_transition()
    transition_active = false
    transition_time = 0
    previous_zone = nil
end

return M
