-- Shared bake/runtime contract for generated elevator resources.
-- Kept Defold-global-free so editor hooks and standalone validators can use it.

local M = {}

M.VERSION = 1
-- Generated elevator resources live below this reserved subtree instead of
-- beside creator-authored room resources. A room called "mine_lift" can then
-- never be overwritten by an elevator whose sanitized id is also mine_lift.
M.RESOURCE_SUBDIR = "_mvtk_elevators"
M.PATHS = {
    controller_script = "/mvtk/prefabs/elevator_controller.script",
    controller_go = "/mvtk/prefabs/elevator_controller.go",
    node_script = "/mvtk/prefabs/elevator_node.script",
    node_go = "/mvtk/prefabs/elevator_node.go",
    cabin_script = "/mvtk/prefabs/elevator_cabin.script",
    collision_forwarder = "/mvtk/prefabs/platform_collision_forwarder.script",
    generated_index = "developer.config.elevators_generated",
}

M.CONTROLLER_PROPERTIES = {
    "elevator_id", "trigger_id", "cabin_resource_key", "start_node_id", "home_stop",
    "speed", "acceleration", "deceleration", "endpoint_wait", "start_delay",
    "close_time", "open_time", "ready_timeout", "seam_y", "seam_y_authored",
    "route_mode", "enabled",
    "activation_mode", "require_interact", "floor_offset", "carry_player",
    "carry_enemies", "carry_pushables", "require_rider", "shaft_clearance",
    "shaft_tolerance", "camera_follow", "camera_lock_x", "camera_look_ahead",
    "camera_blend_time", "camera_priority", "persist_landing", "restore_to_last_landing",
    "width", "height",
}

M.NODE_PROPERTIES = {
    "elevator_id", "node_id", "node_kind", "stop", "room_id", "door_id",
}

M.CABIN_PROPERTIES = {
    "elevator_id", "trigger_id", "cabin_resource_key", "home_stop",
    "bottom_room_id", "top_room_id", "bottom_x", "bottom_y", "bottom_z",
    "top_x", "top_y", "top_z", "seam_y", "seam_y_authored", "speed",
    "acceleration", "deceleration", "endpoint_wait", "start_delay", "close_time",
    "open_time", "ready_timeout", "activation_mode", "require_interact",
    "require_rider", "width", "height", "carry_player", "carry_enemies",
    "carry_pushables", "enabled", "camera_follow", "camera_lock_x",
    "camera_look_ahead", "camera_blend_time", "camera_priority", "camera_url",
    "player_url", "spawn_generation",
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

function M.resource_key(elevator_id)
    local key = trim(elevator_id):lower():gsub("[^%w_]+", "_"):gsub("_+", "_")
    key = key:gsub("^_+", ""):gsub("_+$", "")
    if key == "" then return nil end
    if key:match("^%d") then key = "elevator_" .. key end
    return key
end

local function resource_root(value, fallback)
    local root = trim(value)
    if root == "" then root = fallback end
    root = root:gsub("\\", "/"):gsub("/+$", "")
    if root:sub(1, 1) ~= "/" then root = "/" .. root end
    return root
end

function M.resource_roots(generated_root)
    local suffix = "/" .. M.RESOURCE_SUBDIR
    return {
        generated = resource_root(generated_root, "/developer/rooms/generated") .. suffix,
        collections = "/developer/rooms/collections" .. suffix,
        factories = "/developer/rooms/factories" .. suffix,
    }
end

-- Return every generated filename and Defold resource path as one atomic
-- bundle. Editor generation and the factory holder must use the same bundle so
-- a future path change cannot silently leave a broken collectionfactory URL.
function M.resource_bundle(elevator_id_or_key, generated_root)
    local key = M.resource_key(elevator_id_or_key)
    if not key then return nil, "invalid_elevator_resource_key" end

    local roots = M.resource_roots(generated_root)
    local tilemap_name = key .. ".tilemap"
    local cabin_go_name = key .. ".go"
    local collision_go_name = key .. "_collision.go"
    local collection_name = key .. ".collection"
    local factory_name = key .. "_factory.collectionfactory"
    return {
        key = key,
        tilemap_name = tilemap_name,
        cabin_go_name = cabin_go_name,
        collision_go_name = collision_go_name,
        collection_name = collection_name,
        factory_name = factory_name,
        tilemap_resource = roots.generated .. "/" .. tilemap_name,
        cabin_go_resource = roots.generated .. "/" .. cabin_go_name,
        collision_go_resource = roots.generated .. "/" .. collision_go_name,
        collection_resource = roots.collections .. "/" .. collection_name,
        factory_resource = roots.factories .. "/" .. factory_name,
    }
end

function M.factory_component_id(resource_key)
    local key = M.resource_key(resource_key)
    return key and ("elevator_factory_" .. key) or nil
end

function M.generate_marker_go(kind)
    local script
    if kind == "controller" or kind == "elevator" then
        script = M.PATHS.controller_script
    elseif kind == "node" or kind == "elevator_node" then
        script = M.PATHS.node_script
    else
        return nil, "unknown_elevator_marker_kind"
    end
    return table.concat({
        "components {",
        '  id: "script"',
        string.format('  component: "%s"', script),
        "}",
        "",
    }, "\n")
end

function M.collision_geometry(options)
    options = options or {}
    local width = tonumber(options.width) or 0
    local height = tonumber(options.height) or 0
    if width <= 0 or height <= 0 then return nil, "invalid_cabin_size" end
    local sensor_height = math.max(1, tonumber(options.sensor_height) or 8)
    local solid_center_y = height * 0.5 + (tonumber(options.co_y_offset) or 0)
    local solid_half_height = height * 0.5
    return {
        solid = {
            center_x = width * 0.5,
            center_y = solid_center_y,
            half_width = width * 0.5,
            half_height = solid_half_height,
        },
        sensor = {
            center_x = width * 0.5,
            -- Straddle the walking surface so a collider resting on the
            -- kinematic body overlaps instead of merely touching the sensor.
            center_y = solid_center_y + solid_half_height
                + (tonumber(options.sensor_y_offset) or 0),
            half_width = width * 0.5,
            half_height = sensor_height * 0.5,
        },
    }
end

local function number(value)
    return string.format("%.6g", tonumber(value) or 0)
end

-- Optional helper for generators that do not use hooks/core/elevator_resources.
-- The collision child must be parented to the persistent cabin root.
function M.generate_collision_go(options)
    local geometry, err = M.collision_geometry(options)
    if not geometry then return nil, err end
    local solid, sensor = geometry.solid, geometry.sensor
    local lines = {
        "components {",
        '  id: "script"',
        string.format('  component: "%s"', M.PATHS.collision_forwarder),
        "}",
        "embedded_components {",
        '  id: "co"',
        '  type: "collisionobject"',
        '  data: "type: COLLISION_OBJECT_TYPE_KINEMATIC\\n"',
        '  "mass: 0.0\\n"',
        '  "friction: 0.1\\n"',
        '  "restitution: 0.0\\n"',
        '  "group: \\"solid\\"\\n"',
        '  "mask: \\"player\\"\\n"',
        '  "mask: \\"enemy\\"\\n"',
        '  "mask: \\"world\\"\\n"',
        '  "embedded_collision_shape {\\n"',
        '  "  shapes {\\n"',
        '  "    shape_type: TYPE_BOX\\n"',
        string.format('  "    position { x: %s y: %s z: 0.0 }\\n"',
            number(solid.center_x), number(solid.center_y)),
        '  "    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n"',
        '  "    index: 0\\n"',
        '  "    count: 3\\n"',
        '  "  }\\n"',
        string.format('  "  data: %s\\n"', number(solid.half_width)),
        string.format('  "  data: %s\\n"', number(solid.half_height)),
        '  "  data: 10.0\\n"',
        '  "}\\n"',
        '  ""',
        "}",
        "embedded_components {",
        '  id: "sensor"',
        '  type: "collisionobject"',
        '  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\\n"',
        '  "mass: 0.0\\n"',
        '  "friction: 0.0\\n"',
        '  "restitution: 0.0\\n"',
        -- Rider bodies/tags also mask `solid`; pushables advertise a distinct
        -- tag so unrelated WORLD objects never become passengers.
        '  "group: \\"solid\\"\\n"',
        '  "mask: \\"player\\"\\n"',
        '  "mask: \\"enemy\\"\\n"',
        '  "mask: \\"pushable\\"\\n"',
        '  "embedded_collision_shape {\\n"',
        '  "  shapes {\\n"',
        '  "    shape_type: TYPE_BOX\\n"',
        string.format('  "    position { x: %s y: %s z: 0.0 }\\n"',
            number(sensor.center_x), number(sensor.center_y)),
        '  "    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n"',
        '  "    index: 0\\n"',
        '  "    count: 3\\n"',
        '  "  }\\n"',
        string.format('  "  data: %s\\n"', number(sensor.half_width)),
        string.format('  "  data: %s\\n"', number(sensor.half_height)),
        '  "  data: 10.0\\n"',
        '  "}\\n"',
        '  ""',
        "}",
        "",
    }
    return table.concat(lines, "\n")
end

return M
