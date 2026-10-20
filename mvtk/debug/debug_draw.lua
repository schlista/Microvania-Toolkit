-- mvtk/debug/debug_draw.lua
-- Debug visualization for collision boxes, hitboxes, and other debug shapes

local M = {}

-- Debug draw settings
M.settings = {
    draw_collision_boxes = false,
    draw_hitboxes = false,
    draw_triggers = false,
    draw_raycast = false,
}

-- Color constants
local COLOR = {
    COLLISION_BOX = vmath.vector4(0, 1, 0, 0.5),      -- Green
    HITBOX = vmath.vector4(1, 0, 0, 0.5),              -- Red
    TRIGGER = vmath.vector4(0, 0, 1, 0.5),            -- Blue
    RAYCAST = vmath.vector4(1, 1, 0, 1.0),            -- Yellow
    GROUND = vmath.vector4(0.5, 1, 0.5, 0.5),         -- Light green
    WALL = vmath.vector4(1, 0.5, 0, 0.5),             -- Orange
}

-- Stored debug shapes (for persistent rendering)
M.shapes = {
    boxes = {},
    circles = {},
    lines = {},
    text = {},
}

-----------------------------------------------------------
-- SETTINGS
-----------------------------------------------------------

function M.set_draw_collision_boxes(enabled)
    M.settings.draw_collision_boxes = enabled
    if enabled then
        msg.post("@render:", "debug_physics_toggle", {})
    end
end

function M.set_draw_hitboxes(enabled)
    M.settings.draw_hitboxes = enabled
end

function M.set_draw_triggers(enabled)
    M.settings.draw_triggers = enabled
end

-----------------------------------------------------------
-- DRAWING FUNCTIONS
-----------------------------------------------------------

-- Draw a box (rectangle)
function M.draw_box(position, size, color)
    color = color or COLOR.COLLISION_BOX

    -- Draw using msg.post to @render: or use debug rendering
    msg.post("@render:", "draw_debug_box", {
        position = position,
        size = size,
        color = color
    })
end

-- Draw a circle
function M.draw_circle(position, radius, color)
    color = color or COLOR.HITBOX

    msg.post("@render:", "draw_debug_circle", {
        position = position,
        radius = radius,
        color = color
    })
end

-- Draw a line
function M.draw_line(start_pos, end_pos, color)
    color = color or COLOR.RAYCAST

    msg.post("@render:", "draw_debug_line", {
        start_pos = start_pos,
        end_pos = end_pos,
        color = color
    })
end

-- Draw text at world position
function M.draw_text(position, text, color)
    color = color or vmath.vector4(1, 1, 1, 1)

    msg.post("@render:", "draw_debug_text", {
        position = position,
        text = text,
        color = color
    })
end

-----------------------------------------------------------
-- HELPER FUNCTIONS FOR COMMON DEBUG VISUALIZATION
-----------------------------------------------------------

-- Draw player collision box
function M.draw_player_collision(position, half_width, half_height)
    if not M.settings.draw_collision_boxes then return end

    local size = vmath.vector3(half_width * 2, half_height * 2, 0)
    M.draw_box(position, size, COLOR.COLLISION_BOX)
end

-- Draw attack hitbox
function M.draw_attack_hitbox(position, size)
    if not M.settings.draw_hitboxes then return end

    M.draw_box(position, size, COLOR.HITBOX)
end

-- Draw ground detection raycast
function M.draw_ground_raycast(from, to, hit)
    if not M.settings.draw_collision_boxes then return end

    local color = hit and COLOR.GROUND or COLOR.RAYCAST
    M.draw_line(from, to, color)

    if hit then
        M.draw_circle(to, 4, COLOR.GROUND)
    end
end

-- Draw wall detection
function M.draw_wall_detection(position, direction, distance, hit)
    if not M.settings.draw_collision_boxes then return end

    local end_pos = position + direction * distance
    local color = hit and COLOR.WALL or COLOR.RAYCAST

    M.draw_line(position, end_pos, color)

    if hit then
        M.draw_circle(end_pos, 4, COLOR.WALL)
    end
end

-----------------------------------------------------------
-- PHYSICS DEBUG VISUALIZATION
-----------------------------------------------------------

-- Enable Defold's built-in physics debug rendering
function M.enable_physics_debug()
    msg.post("@system:", "toggle_physics_debug")
    print("✅ Physics debug rendering enabled")
end

-- Disable physics debug rendering
function M.disable_physics_debug()
    msg.post("@system:", "toggle_physics_debug")
    print("❌ Physics debug rendering disabled")
end

-----------------------------------------------------------
-- PERSISTENT SHAPES
-----------------------------------------------------------

-- Add a persistent box (rendered every frame until cleared)
function M.add_persistent_box(id, position, size, color)
    M.shapes.boxes[id] = {
        position = position,
        size = size,
        color = color or COLOR.COLLISION_BOX
    }
end

-- Remove persistent box
function M.remove_persistent_box(id)
    M.shapes.boxes[id] = nil
end

-- Clear all persistent shapes
function M.clear_all_shapes()
    M.shapes.boxes = {}
    M.shapes.circles = {}
    M.shapes.lines = {}
    M.shapes.text = {}
end

-----------------------------------------------------------
-- UPDATE (Call from render script if implementing custom debug rendering)
-----------------------------------------------------------

function M.update(dt)
    -- Render persistent shapes
    for id, box in pairs(M.shapes.boxes) do
        M.draw_box(box.position, box.size, box.color)
    end

    for id, circle in pairs(M.shapes.circles) do
        M.draw_circle(circle.position, circle.radius, circle.color)
    end

    for id, line in pairs(M.shapes.lines) do
        M.draw_line(line.start_pos, line.end_pos, line.color)
    end

    for id, text in pairs(M.shapes.text) do
        M.draw_text(text.position, text.text, text.color)
    end
end

-----------------------------------------------------------
-- UTILITY FUNCTIONS
-----------------------------------------------------------

-- Draw a coordinate cross at position
function M.draw_cross(position, size, color)
    size = size or 20
    color = color or vmath.vector4(1, 1, 1, 1)

    local offset = size / 2
    M.draw_line(
        position + vmath.vector3(-offset, 0, 0),
        position + vmath.vector3(offset, 0, 0),
        color
    )
    M.draw_line(
        position + vmath.vector3(0, -offset, 0),
        position + vmath.vector3(0, offset, 0),
        color
    )
end

-- Draw a grid
function M.draw_grid(center, cell_size, grid_width, grid_height, color)
    color = color or vmath.vector4(0.3, 0.3, 0.3, 0.5)

    local half_width = (grid_width * cell_size) / 2
    local half_height = (grid_height * cell_size) / 2

    -- Vertical lines
    for x = -grid_width/2, grid_width/2 do
        local x_pos = center.x + x * cell_size
        M.draw_line(
            vmath.vector3(x_pos, center.y - half_height, 0),
            vmath.vector3(x_pos, center.y + half_height, 0),
            color
        )
    end

    -- Horizontal lines
    for y = -grid_height/2, grid_height/2 do
        local y_pos = center.y + y * cell_size
        M.draw_line(
            vmath.vector3(center.x - half_width, y_pos, 0),
            vmath.vector3(center.x + half_width, y_pos, 0),
            color
        )
    end
end

return M
