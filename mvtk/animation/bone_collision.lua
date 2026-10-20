-- mvtk/animation/bone_collision.lua
-- Track Spine bone positions for dynamic collision detection

local M = {}
local SurfaceClassifier = require "mvtk.core.surface_classifier"

-- Get the world position and rotation of a bone
-- Returns: position (vector3), rotation (quaternion) or nil if bone doesn't exist
function M.get_bone_world_transform(spine_url, bone_name)
    if not spine_url or not bone_name then
        return nil
    end

    local ok, result_or_error = pcall(function()
        -- Use spine.get_go() to get the bone game object
        local bone_go = spine.get_go(spine_url, bone_name)
        if not bone_go then
            return nil
        end
        
        -- Get the world position of the bone game object
        local world_pos = go.get_world_position(bone_go)
        return world_pos
    end)

    if ok and result_or_error then
        return result_or_error
    else
        -- Log the error for debugging
        if not ok then
            print(string.format("[BONE_COLLISION] Error getting bone '%s': %s", bone_name, tostring(result_or_error)))
        end
    end
    return nil
end

-- Get just the world position of a bone
function M.get_bone_position(spine_url, bone_name)
    local pos, _ = M.get_bone_world_transform(spine_url, bone_name)
    return pos
end

-- Check if a point is near a bone (useful for hit detection)
function M.is_near_bone(spine_url, bone_name, point, radius)
    local bone_pos = M.get_bone_position(spine_url, bone_name)
    if not bone_pos or not point then return false end

    radius = radius or 20
    local dist = vmath.length(point - bone_pos)
    return dist <= radius
end

-- Raycast from a bone position in a direction
function M.bone_raycast(spine_url, bone_name, direction, distance, groups)
    local bone_pos = M.get_bone_position(spine_url, bone_name)
    if not bone_pos then return nil end

    direction = vmath.normalize(direction or vmath.vector3(0, -1, 0))
    distance = distance or 50
    groups = groups or SurfaceClassifier.RAYCAST.GROUND

    local from = bone_pos
    local to = bone_pos + (direction * distance)

    return physics.raycast(from, to, groups)
end

-- Get positions of both BeardyBuck feet (far layer first, near layer second).
function M.get_feet_positions(spine_url)
    local far_foot = M.get_bone_position(spine_url, "foot_far")
    local near_foot = M.get_bone_position(spine_url, "foot_near")

    return far_foot, near_foot
end

-- Get positions of both BeardyBuck hands (far layer first, near layer second).
function M.get_hand_positions(spine_url)
    local far_hand = M.get_bone_position(spine_url, "hand_far")
    local near_hand = M.get_bone_position(spine_url, "hand_near")

    return far_hand, near_hand
end

-- Check if either foot is touching the ground
function M.check_feet_grounded(spine_url, check_distance)
    check_distance = check_distance or 8

    local far_foot, near_foot = M.get_feet_positions(spine_url)

    local far_grounded = false
    local near_grounded = false

    if far_foot then
        local result = M.bone_raycast(spine_url, "foot_far", vmath.vector3(0, -1, 0), check_distance)
        far_grounded = result ~= nil
    end

    if near_foot then
        local result = M.bone_raycast(spine_url, "foot_near", vmath.vector3(0, -1, 0), check_distance)
        near_grounded = result ~= nil
    end

    return far_grounded or near_grounded, far_grounded, near_grounded
end

-- Create a circular hitbox at a bone position
-- Returns a table with position and radius for collision checks
function M.create_bone_hitbox(spine_url, bone_name, radius, offset)
    local bone_pos = M.get_bone_position(spine_url, bone_name)
    if not bone_pos then return nil end

    offset = offset or vmath.vector3(0, 0, 0)
    radius = radius or 25

    return {
        position = bone_pos + offset,
        radius = radius,
        bone_name = bone_name
    }
end

-- Check if a hitbox overlaps with a point
function M.hitbox_contains_point(hitbox, point)
    if not hitbox or not point then return false end
    local dist = vmath.length(point - hitbox.position)
    return dist <= hitbox.radius
end

-- Check if two hitboxes overlap
function M.hitboxes_overlap(hitbox1, hitbox2)
    if not hitbox1 or not hitbox2 then return false end
    local dist = vmath.length(hitbox1.position - hitbox2.position)
    local combined_radius = hitbox1.radius + hitbox2.radius
    return dist <= combined_radius
end

-- Helper: Get spine URL from current game object
function M.get_spine_url(spine_component_id)
    spine_component_id = spine_component_id or "spine"
    return msg.url(nil, go.get_id(), spine_component_id)
end

return M
