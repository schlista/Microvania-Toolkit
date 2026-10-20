-- mvtk/animation/bone_debug_draw.lua
-- Visual debugging for bone positions

local M = {}
local BoneCollision = require "mvtk.animation.bone_collision"

-- Draw a circle at a bone position
local function draw_bone_marker(position, color, radius)
    if not position then return end

    color = color or vmath.vector4(1, 0, 0, 1)  -- Default red
    radius = radius or 10

    -- Draw a cross at the bone position
    msg.post("@render:", "draw_line", {
        start_point = position + vmath.vector3(-radius, 0, 0),
        end_point = position + vmath.vector3(radius, 0, 0),
        color = color
    })
    msg.post("@render:", "draw_line", {
        start_point = position + vmath.vector3(0, -radius, 0),
        end_point = position + vmath.vector3(0, radius, 0),
        color = color
    })
end

-- Draw hitbox circle
local function draw_hitbox(hitbox, color)
    if not hitbox or not hitbox.position then return end

    color = color or vmath.vector4(1, 1, 0, 0.5)  -- Default yellow

    -- Draw 8 points around the circle
    local segments = 16
    for i = 0, segments do
        local angle1 = (i / segments) * math.pi * 2
        local angle2 = ((i + 1) / segments) * math.pi * 2

        local x1 = hitbox.position.x + math.cos(angle1) * hitbox.radius
        local y1 = hitbox.position.y + math.sin(angle1) * hitbox.radius
        local x2 = hitbox.position.x + math.cos(angle2) * hitbox.radius
        local y2 = hitbox.position.y + math.sin(angle2) * hitbox.radius

        msg.post("@render:", "draw_line", {
            start_point = vmath.vector3(x1, y1, 0),
            end_point = vmath.vector3(x2, y2, 0),
            color = color
        })
    end
end

-- Debug draw feet positions
function M.draw_feet(spine_url)
    local far_foot, near_foot = BoneCollision.get_feet_positions(spine_url)

    if far_foot then
        draw_bone_marker(far_foot, vmath.vector4(0, 1, 0, 1), 8)  -- Green for far layer
    end

    if near_foot then
        draw_bone_marker(near_foot, vmath.vector4(0, 0, 1, 1), 8)  -- Blue for near layer
    end
end

-- Debug draw hands positions
function M.draw_hands(spine_url)
    local far_hand, near_hand = BoneCollision.get_hand_positions(spine_url)

    if far_hand then
        draw_bone_marker(far_hand, vmath.vector4(1, 1, 0, 1), 10)  -- Yellow for far layer
    end

    if near_hand then
        draw_bone_marker(near_hand, vmath.vector4(1, 0, 1, 1), 10)  -- Magenta for near layer
    end
end

-- Debug draw a specific bone
function M.draw_bone(spine_url, bone_name, color, radius)
    local pos = BoneCollision.get_bone_position(spine_url, bone_name)
    if pos then
        draw_bone_marker(pos, color, radius)
    end
end

-- Debug draw attack hitbox
function M.draw_attack_hitbox(hitbox)
    if hitbox then
        draw_hitbox(hitbox, vmath.vector4(1, 0, 0, 0.7))  -- Red circle
    end
end

-- Debug draw all major bones
function M.draw_all_debug(spine_url)
    M.draw_feet(spine_url)
    M.draw_hands(spine_url)

    -- Draw head
    M.draw_bone(spine_url, "head", vmath.vector4(1, 1, 1, 1), 12)

    -- Draw waist (center)
    M.draw_bone(spine_url, "waist", vmath.vector4(0.5, 0.5, 0.5, 1), 8)
end

return M
