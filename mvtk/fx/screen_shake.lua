-- mvtk/fx/screen_shake.lua
-- Enhanced screen shake system with multiple intensities and decay
-- Makes impacts feel powerful by shaking the camera

local M = {}

-- Configuration
local DECAY_RATE = 5.0  -- How fast shake diminishes per second

-- State
local shake_trauma = 0  -- Current shake trauma (0-1)
local shake_offset = vmath.vector3(0, 0, 0)
local ZERO_VEC3 = vmath.vector3(0, 0, 0)  -- Cached zero vector (read-only reference)
local max_offset = 16  -- Maximum pixel offset at full trauma

-- Shake settings
local shake_settings = {
    light = { trauma = 0.2, max_offset = 8 },
    medium = { trauma = 0.4, max_offset = 16 },
    heavy = { trauma = 0.7, max_offset = 32 },
    critical = { trauma = 1.0, max_offset = 48 }
}

--- Initialize the screen shake system
function M.init()
    shake_trauma = 0
    shake_offset.x = 0
    shake_offset.y = 0
    shake_offset.z = 0
end

--- Update screen shake (call from main update loop)
-- @param dt Delta time
function M.update(dt)
    if shake_trauma <= 0 then
        shake_offset.x = 0
        shake_offset.y = 0
        shake_offset.z = 0
        return
    end

    -- Decay trauma over time
    shake_trauma = math.max(0, shake_trauma - DECAY_RATE * dt)

    -- Calculate shake intensity (squared for smoother falloff)
    local shake_intensity = shake_trauma * shake_trauma

    -- Generate random offset based on intensity
    local angle = math.random() * math.pi * 2
    local magnitude = shake_intensity * max_offset

    shake_offset.x = math.cos(angle) * magnitude
    shake_offset.y = math.sin(angle) * magnitude
end

--- Add trauma to trigger shake
-- @param amount Trauma amount (0-1), higher = more intense
function M.add_trauma(amount)
    shake_trauma = math.min(1.0, shake_trauma + amount)
end

--- Trigger screen shake with preset intensity
-- @param intensity "light", "medium", "heavy", or "critical"
function M.shake(intensity)
    local settings = shake_settings[intensity] or shake_settings.medium

    shake_trauma = math.min(1.0, shake_trauma + settings.trauma)
    max_offset = math.max(max_offset, settings.max_offset)
end

--- Get current shake offset to apply to camera
-- @return Vector3 offset
function M.get_offset()
    return shake_offset
end

--- Get current trauma level
-- @return Trauma value (0-1)
function M.get_trauma()
    return shake_trauma
end

--- Stop all shaking immediately
function M.stop()
    shake_trauma = 0
    shake_offset.x = 0
    shake_offset.y = 0
    shake_offset.z = 0
end

--- Convenience function: light shake (normal hit)
function M.on_hit_light()
    M.shake("light")
end

--- Convenience function: medium shake (heavy attack)
function M.on_hit_medium()
    M.shake("medium")
end

--- Convenience function: heavy shake (charged attack, explosion)
function M.on_hit_heavy()
    M.shake("heavy")
end

--- Convenience function: critical shake (killing blow, boss impact)
function M.on_hit_critical()
    M.shake("critical")
end

--- Apply shake to camera position
-- Call this in your camera update to apply shake offset
-- @param camera_pos Current camera position
-- @return Modified camera position with shake applied
function M.apply_to_camera(camera_pos)
    return camera_pos + shake_offset
end

return M
