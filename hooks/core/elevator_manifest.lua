-- hooks/core/elevator_manifest.lua
--
-- Cross-room elevator authoring scanner.  This module intentionally performs
-- no file I/O: editor_commands supplies the room ids and its canonical Tiled
-- export loader, then decides how/where to serialize the returned manifest.

local Contract = require "mvtk.elevators.elevator_contract"

local M = {}

M.VERSION = 1

local DEFAULT_SETTINGS = {
    speed = 96,
    acceleration = 384,
    deceleration = 384,
    endpoint_wait = 0.35,
    start_delay = 0,
    close_time = 0.25,
    open_time = 0.25,
    ready_timeout = 5,
    route_mode = "pingpong",
    enabled = true,
    activation_mode = "on_board",
    trigger_id = "",
    require_interact = false,
    floor_offset = 32,
    co_y_offset = 0,
    sensor_y_offset = 0,
    carry_player = true,
    carry_enemies = false,
    carry_pushables = true,
    require_rider = true,
    shaft_clearance = 0,
    shaft_tolerance = 0.5,
    camera_follow = true,
    camera_lock_x = true,
    camera_look_ahead = 96,
    camera_blend_time = 0.2,
    camera_priority = 50,
    persist_landing = true,
    restore_to_last_landing = true,
    source_layer = "environment",
    clear_source_tiles = true,
    use_defold_sprite = false,
    visual_z = 0.5,
}

local PROPERTY_REGISTRY = {
    groups = {
        motion_and_timing = { members = {
            speed = { default = 96 },
            acceleration = { default = 384 },
            deceleration = { default = 384 },
            endpoint_wait = { default = 0.35 },
            start_delay = { default = 0 },
            close_time = { default = 0.25 },
            open_time = { default = 0.25 },
            ready_timeout = { default = 5 },
            route_mode = { default = "pingpong" },
        } },
        activation = { members = {
            enabled = { default = true },
            activation_mode = { default = "on_board" },
            trigger_id = { default = "" },
            require_interact = { default = false },
        } },
        collision_and_rider = { members = {
            floor_offset = { default = 32 },
            co_y_offset = { default = 0 },
            sensor_y_offset = { default = 0 },
            carry_player = { default = true },
            carry_enemies = { default = false },
            carry_pushables = { default = true },
            require_rider = { default = true },
            shaft_clearance = { default = 0 },
            shaft_tolerance = { default = 0.5 },
        } },
        camera = { members = {
            camera_follow = { default = true },
            camera_lock_x = { default = true },
            camera_look_ahead = { default = 96 },
            camera_blend_time = { default = 0.2 },
            camera_priority = { default = 50 },
        } },
        persistence = { members = {
            persist_landing = { default = true },
            restore_to_last_landing = { default = true },
        } },
        visuals = { members = {
            source_layer = { default = "environment" },
            clear_source_tiles = { default = true },
            use_defold_sprite = { default = false },
            visual_z = { default = 0.5 },
        } },
        landing = { members = {
            stop_enabled = { default = true },
            dwell_override = { default = -1 },
            call_enabled = { default = true },
            require_flag = { default = "" },
            arrival_message = { default = "" },
            departure_message = { default = "" },
        } },
    },
}

local function trim(value)
    if value == nil then return "" end
    return tostring(value):match("^%s*(.-)%s*$") or ""
end

local function lower_token(value)
    return trim(value):lower():gsub("[%s%-]+", "_")
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do
        result[copy(key, seen)] = copy(child, seen)
    end
    return result
end

local function settings_with_defaults(properties)
    local settings = copy(DEFAULT_SETTINGS)
    for key, value in pairs(properties or {}) do settings[key] = copy(value) end
    return settings
end

local function unwrap(value)
    local seen = {}
    while type(value) == "table" and not seen[value] do
        seen[value] = true
        if rawget(value, "value") ~= nil then
            value = rawget(value, "value")
        elseif rawget(value, "Value") ~= nil then
            value = rawget(value, "Value")
        else
            break
        end
    end
    return value
end

local function fallback_flatten(properties)
    local flattened = {}
    if type(properties) ~= "table" then return flattened, {} end

    local function put(name, value)
        if name and name ~= "" then flattened[tostring(name)] = copy(unwrap(value)) end
    end

    for key, value in pairs(properties) do
        if type(key) == "string" then
            local unwrapped = unwrap(value)
            if type(unwrapped) == "table" then
                local found_member = false
                for member, member_value in pairs(unwrapped) do
                    if type(member) == "string" and member ~= "name" and member ~= "type"
                        and member ~= "propertytype" and member ~= "inherited"
                    then
                        found_member = true
                        put(member, member_value)
                    end
                end
                if not found_member then put(key, unwrapped) end
            else
                put(key, unwrapped)
            end
        end
    end
    for _, record in ipairs(properties) do
        if type(record) == "table" then
            put(record.name or record.Name, rawget(record, "value") or rawget(record, "Value"))
        end
    end
    return flattened, {}
end

local function get_flattener(options)
    if type(options.flatten_properties) == "function" then
        return options.flatten_properties
    end
    if type(options.property_flattener) == "table"
        and type(options.property_flattener.flatten) == "function"
    then
        return options.property_flattener.flatten
    end
    local ok, flattener = pcall(require, "mvtk.tiled.property_flattener")
    if ok and type(flattener) == "table" and type(flattener.flatten) == "function" then
        return flattener.flatten
    end
    return fallback_flatten
end

local function flatten_properties(properties, options)
    local flatten = get_flattener(options)
    local ok, flattened, collisions = pcall(flatten, properties or {}, {
        registry = PROPERTY_REGISTRY,
    })
    if ok and type(flattened) == "table" then
        return flattened, type(collisions) == "table" and collisions or {}, nil
    end
    local fallback = fallback_flatten(properties)
    return fallback, {}, tostring(flattened)
end

local function clean_room_id(room_id)
    local result = trim(room_id):gsub("\\", "/")
    result = result:gsub("^%./", ""):gsub("^/", "")
    result = result:gsub("^developer%.rooms%.", "")
    result = result:gsub("%.collectionc?$", "")
    result = result:gsub("%.tilemap$", "")
    result = result:gsub("%.lua$", ""):gsub("%.tmx$", "")
    result = result:gsub("/+$", "")
    result = result:match("([^/]+)$") or result
    return result
end

local function clean_object_id(object_id)
    local number = tonumber(object_id)
    if number and number == math.floor(number) then return tostring(math.floor(number)) end
    return trim(object_id)
end

function M.resource_key(elevator_id)
    return Contract.resource_key(elevator_id)
end

local function add_diagnostic(diagnostics, severity, code, message, context)
    local diagnostic = {
        severity = severity,
        code = code,
        message = message,
    }
    for key, value in pairs(context or {}) do
        if value ~= nil then diagnostic[key] = value end
    end
    diagnostics[#diagnostics + 1] = diagnostic
    return diagnostic
end

function M.has_errors(diagnostics)
    for _, diagnostic in ipairs(diagnostics or {}) do
        if diagnostic.severity == "error" then return true end
    end
    return false
end

-- Return the deterministic room set that must be rebuilt after one or more
-- Tiled Lua exports change. Elevator factories are generated from controller
-- rooms, so a node-only edit must pull its otherwise-unchanged controller room
-- into the same generation transaction.
function M.expand_generation_rooms(changed_room_ids, manifest)
    local generation_ids = {}
    local forced_controller_ids = {}
    local seen = {}

    for _, value in ipairs(changed_room_ids or {}) do
        local room_id = clean_room_id(value)
        if room_id ~= "" and not seen[room_id] then
            seen[room_id] = true
            generation_ids[#generation_ids + 1] = room_id
        end
    end

    for _, elevator_id in ipairs((manifest and manifest.ordered_ids) or {}) do
        local elevator = manifest.elevators and manifest.elevators[elevator_id]
        local controller_room = elevator and elevator.controller
            and clean_room_id(elevator.controller.room_id)
        if controller_room and controller_room ~= "" and not seen[controller_room] then
            seen[controller_room] = true
            generation_ids[#generation_ids + 1] = controller_room
            forced_controller_ids[#forced_controller_ids + 1] = controller_room
        end
    end

    table.sort(generation_ids)
    table.sort(forced_controller_ids)
    return generation_ids, forced_controller_ids
end

local function normalized_kind(value)
    local kind = lower_token(value)
    if kind == "passthrough" then kind = "pass_through" end
    if kind == "stop" then kind = "landing" end
    if kind == "" then kind = "landing" end
    return kind
end

local function normalized_stop(value)
    local stop = lower_token(value)
    if stop == "lower" or stop == "lowest" or stop == "min" then stop = "bottom" end
    if stop == "upper" or stop == "highest" or stop == "max" then stop = "top" end
    if stop == "none" or stop == "pass" or stop == "pass_through" then return nil end
    if stop == "" then return nil end
    return stop
end

local function infer_marker_kind(object, properties)
    local object_type = lower_token(object.type or object.class)
    local name = lower_token(object.name)
    local template = lower_token(object.template or object.template_file or object.templatePath)

    if object_type == "elevator_node" or object_type == "elevator_stop"
        or name == "elevator_node" or name == "elevator_stop"
        or template:match("elevator_node_?tx$")
    then
        return "node"
    end
    if object_type == "elevator" or object_type == "elevator_controller"
        or name == "elevator" or name == "elevator_controller"
        or (template:match("elevator_?tx$") and not template:find("node", 1, true))
    then
        return "controller"
    end
    if properties.node_id ~= nil or properties.node_kind ~= nil then return "node" end
    if properties.start_node_id ~= nil then return "controller" end
    return nil
end

local function object_shape(object)
    local shape = lower_token(object.shape)
    if shape ~= "" then return shape end
    if object.point == true then return "point" end
    if (tonumber(object.width) or 0) == 0 and (tonumber(object.height) or 0) == 0 then
        return "point"
    end
    return "rectangle"
end

local function object_context(room_id, object)
    return {
        room_id = room_id,
        object_id = object and object.id or nil,
    }
end

local function walk_layers(layers, inherited, callback, layer_path)
    inherited = inherited or { offsetx = 0, offsety = 0, visible = true }
    layer_path = layer_path or ""
    for layer_index, layer in ipairs(layers or {}) do
        if type(layer) == "table" then
            local layer_name = trim(layer.name)
            if layer_name == "" then layer_name = "layer_" .. tostring(layer_index) end
            local path = layer_path == "" and layer_name or (layer_path .. "/" .. layer_name)
            local state = {
                offsetx = (tonumber(inherited.offsetx) or 0) + (tonumber(layer.offsetx) or 0),
                offsety = (tonumber(inherited.offsety) or 0) + (tonumber(layer.offsety) or 0),
                visible = inherited.visible ~= false and layer.visible ~= false,
            }
            if layer.type == "group" and type(layer.layers) == "table" then
                walk_layers(layer.layers, state, callback, path)
            elseif layer.type == "objectgroup" or type(layer.objects) == "table" then
                for object_index, object in ipairs(layer.objects or {}) do
                    if type(object) == "table" then
                        callback(object, state, path, object_index)
                    end
                end
            end
        end
    end
end

local function source_sort(a, b)
    if a.room_id ~= b.room_id then return a.room_id < b.room_id end
    local an, bn = tonumber(a.object_id), tonumber(b.object_id)
    if an and bn and an ~= bn then return an < bn end
    if tostring(a.object_id) ~= tostring(b.object_id) then
        return tostring(a.object_id) < tostring(b.object_id)
    end
    return tostring(a.layer_path or "") < tostring(b.layer_path or "")
end

local function ensure_elevator(manifest, elevator_id)
    local entry = manifest.elevators[elevator_id]
    if not entry then
        entry = {
            id = elevator_id,
            resource_key = M.resource_key(elevator_id),
            controllers = {},
            nodes = {},
        }
        manifest.elevators[elevator_id] = entry
    end
    return entry
end

local function scan_map(manifest, diagnostics, room_id, map, source_path, options, sources)
    if type(map) ~= "table" then return end
    local map_height = tonumber(map.height)
    local tile_height = tonumber(map.tileheight)
    local map_height_px = map_height and tile_height and map_height * tile_height or nil

    walk_layers(map.layers, nil, function(object, layer_state, layer_path, object_index)
        local properties, collisions, flatten_error = flatten_properties(object.properties, options)
        local marker_kind = infer_marker_kind(object, properties)
        local has_elevator_property = properties.elevator_id ~= nil
        if not marker_kind and not has_elevator_property then return end

        local context = object_context(room_id, object)
        local source_visible = layer_state.visible ~= false and object.visible ~= false
        -- Hidden authoring markers are intentionally inert. Keep just enough
        -- provenance to explain a broken visible route, but do not let hidden
        -- objects create an elevator or participate in structural validation.
        if not source_visible then
            local hidden_elevator_id = trim(properties.elevator_id)
            if marker_kind and hidden_elevator_id ~= "" then
                manifest.hidden_markers[#manifest.hidden_markers + 1] = {
                    marker_kind = marker_kind,
                    elevator_id = hidden_elevator_id,
                    node_id = marker_kind == "node" and trim(properties.node_id) or nil,
                    start_node_id = marker_kind == "controller"
                        and trim(properties.start_node_id) or nil,
                    room_id = room_id,
                    object_id = object.id,
                    source_key = room_id .. ":" .. clean_object_id(object.id),
                    source_path = source_path,
                    layer_path = layer_path,
                    source_visible = false,
                }
            end
            return
        end
        if flatten_error then
            add_diagnostic(diagnostics, "warning", "property_flatten_failed",
                "Could not use the canonical grouped-property flattener; compatibility flattening was used: "
                    .. flatten_error, context)
        end
        if not marker_kind then
            add_diagnostic(diagnostics, "error", "ambiguous_elevator_object",
                "Object has elevator_id but is neither an elevator controller nor an elevator node.", context)
            return
        end

        local elevator_id = trim(properties.elevator_id)
        if elevator_id == "" then
            add_diagnostic(diagnostics, "error", "empty_elevator_id",
                "Elevator controllers and nodes require a non-empty elevator_id.", context)
            return
        end
        context.elevator_id = elevator_id

        if not map_height_px or map_height_px <= 0 then
            add_diagnostic(diagnostics, "error", "invalid_map_height",
                "The Tiled map needs positive height and tileheight values to resolve room-local Y coordinates.",
                context)
            return
        end

        local object_id = clean_object_id(object.id)
        if object_id == "" then
            add_diagnostic(diagnostics, "error", "missing_object_id",
                "Elevator objects require a stable Tiled object id.", context)
            object_id = "missing_" .. tostring(layer_path) .. "_" .. tostring(object_index)
        end
        local source_key = room_id .. ":" .. object_id
        if sources[source_key] then
            add_diagnostic(diagnostics, "error", "duplicate_source_key",
                "More than one elevator object resolves to source key " .. source_key .. ".", context)
        else
            sources[source_key] = true
        end

        local raw_x = tonumber(object.x) or 0
        local raw_y = tonumber(object.y) or 0
        local width = tonumber(object.width) or 0
        local height = tonumber(object.height) or 0
        local effective_x = raw_x + (tonumber(layer_state.offsetx) or 0)
        local effective_y = raw_y + (tonumber(layer_state.offsety) or 0)
        local local_y = map_height_px - effective_y
        if marker_kind == "controller" then local_y = local_y - height end

        local marker = {
            elevator_id = elevator_id,
            room_id = room_id,
            object_id = object.id,
            source_key = source_key,
            source_path = source_path,
            layer_path = layer_path,
            source_visible = true,
            name = object.name,
            object_type = object.type or object.class,
            shape = object_shape(object),
            rotation = tonumber(object.rotation) or 0,
            local_x = effective_x,
            local_y = local_y,
            tiled_x = effective_x,
            tiled_y = effective_y,
            width = width,
            height = height,
            map_width_tiles = tonumber(map.width),
            map_height_tiles = tonumber(map.height),
            tile_width = tonumber(map.tilewidth),
            tile_height = tonumber(map.tileheight),
            properties = copy(properties),
            property_diagnostics = copy(collisions),
        }

        local elevator = ensure_elevator(manifest, elevator_id)
        if marker_kind == "node" then
            marker.node_id = trim(properties.node_id)
            marker.kind = normalized_kind(properties.node_kind)
            marker.stop = normalized_stop(properties.stop)
            marker.door_id = trim(properties.door_id)
            marker.runtime_stop = marker.kind == "landing"
                and (marker.stop == "bottom" or marker.stop == "top")
            elevator.nodes[#elevator.nodes + 1] = marker
        else
            marker.start_node_id = trim(properties.start_node_id)
            elevator.controllers[#elevator.controllers + 1] = marker
        end
    end)
end

local function sorted_elevator_ids(manifest)
    local ids = {}
    for elevator_id in pairs(manifest.elevators or {}) do ids[#ids + 1] = elevator_id end
    table.sort(ids)
    return ids
end

local function diag_context(elevator, marker)
    return {
        elevator_id = elevator and elevator.id or nil,
        room_id = marker and marker.room_id or nil,
        object_id = marker and marker.object_id or nil,
        source_key = marker and marker.source_key or nil,
    }
end

function M.validate(manifest, diagnostics)
    diagnostics = diagnostics or {}
    manifest.elevators = manifest.elevators or {}
    manifest.hidden_markers = manifest.hidden_markers or {}
    table.sort(manifest.hidden_markers, source_sort)
    manifest.ordered_ids = sorted_elevator_ids(manifest)

    local resource_owners = {}
    for _, elevator_id in ipairs(manifest.ordered_ids) do
        local elevator = manifest.elevators[elevator_id]
        if type(elevator.controllers) ~= "table" then
            elevator.controllers = elevator.controller and { elevator.controller } or {}
        end
        if type(elevator.nodes) ~= "table" then elevator.nodes = {} end
        table.sort(elevator.controllers or {}, source_sort)
        table.sort(elevator.nodes or {}, source_sort)
        elevator.controller = elevator.controllers and elevator.controllers[1] or nil
        elevator.settings = elevator.controller and settings_with_defaults(elevator.controller.properties)
            or settings_with_defaults()
        elevator.nodes_by_id = {}
        elevator.room_ids = {}

        local resource_owner = elevator.resource_key
            and resource_owners[elevator.resource_key] or nil
        if not elevator.resource_key then
            add_diagnostic(diagnostics, "error", "invalid_elevator_resource_id",
                string.format(
                    "Elevator id %q must contain at least one ASCII letter, number, or underscore for generated resources.",
                    elevator_id), diag_context(elevator))
        elseif resource_owner and resource_owner ~= elevator_id then
            add_diagnostic(diagnostics, "error", "resource_key_collision",
                string.format("Elevators %q and %q share generated resource key %q.",
                    resource_owner, elevator_id, elevator.resource_key), diag_context(elevator))
        else
            resource_owners[elevator.resource_key] = elevator_id
        end

        local controller_count = #(elevator.controllers or {})
        if controller_count == 0 then
            add_diagnostic(diagnostics, "error", "missing_controller",
                "Each elevator_id must have exactly one elevator controller.", diag_context(elevator))
        elseif controller_count > 1 then
            add_diagnostic(diagnostics, "error", "duplicate_controller",
                string.format("Elevator %q has %d controllers; keep exactly one.", elevator_id, controller_count),
                diag_context(elevator, elevator.controllers[2]))
        end

        if elevator.controller then
            local controller = elevator.controller
            if controller.shape ~= "rectangle" or controller.width <= 0 or controller.height <= 0 then
                add_diagnostic(diagnostics, "error", "invalid_controller_bounds",
                    "The elevator controller must be a positive-size rectangle representing the cabin.",
                    diag_context(elevator, controller))
            end
            if math.abs(controller.rotation or 0) > 0.0001 then
                add_diagnostic(diagnostics, "error", "rotated_controller",
                    "Elevator controllers cannot be rotated.", diag_context(elevator, controller))
            end
            local settings = elevator.settings
            local activation_mode = lower_token(settings.activation_mode)
            if activation_mode ~= "on_board" and activation_mode ~= "automatic"
                and activation_mode ~= "trigger_only"
            then
                add_diagnostic(diagnostics, "error", "invalid_activation_mode",
                    "activation_mode must be on_board, automatic, or trigger_only.",
                    diag_context(elevator, controller))
            end
            local route_mode = lower_token(settings.route_mode)
            if route_mode ~= "pingpong" then
                add_diagnostic(diagnostics, "error", "invalid_route_mode",
                    "Two-terminal cross-room elevators currently require route_mode=pingpong.",
                    diag_context(elevator, controller))
            end
            if settings.require_interact == true and activation_mode ~= "on_board" then
                add_diagnostic(diagnostics, "error", "incompatible_elevator_activation",
                    "require_interact is only valid with activation_mode=on_board.",
                    diag_context(elevator, controller))
            end
            if settings.clear_source_tiles == false then
                add_diagnostic(diagnostics, "error", "unsupported_elevator_tile_copy",
                    "Persistent elevator cabin tiles must be removed from the streamed source room.",
                    diag_context(elevator, controller))
            end
            if settings.use_defold_sprite == true then
                add_diagnostic(diagnostics, "error", "unsupported_elevator_sprite",
                    "Elevator cabins use the painted Tiled tilemap; use_defold_sprite is not supported.",
                    diag_context(elevator, controller))
            end
            local speed = tonumber(settings.speed)
            if not speed or speed <= 0 then
                add_diagnostic(diagnostics, "error", "invalid_speed",
                    "Elevator speed must be greater than zero.", diag_context(elevator, controller))
            end
            for _, property in ipairs({ "acceleration", "deceleration", "endpoint_wait",
                "start_delay", "close_time", "open_time" })
            do
                local value = tonumber(settings[property])
                if value == nil or value < 0 then
                    add_diagnostic(diagnostics, "error", "invalid_" .. property,
                        property .. " must be a non-negative number.", diag_context(elevator, controller))
                end
            end
            local ready_timeout = tonumber(settings.ready_timeout)
            if not ready_timeout or ready_timeout <= 0 then
                add_diagnostic(diagnostics, "error", "invalid_ready_timeout",
                    "ready_timeout must be greater than zero.", diag_context(elevator, controller))
            end
            local shaft_tolerance = tonumber(settings.shaft_tolerance)
            if not shaft_tolerance or shaft_tolerance < 0 then
                add_diagnostic(diagnostics, "error", "invalid_shaft_tolerance",
                    "shaft_tolerance must be a non-negative number.", diag_context(elevator, controller))
            end
            if tonumber(settings.camera_priority) == nil then
                add_diagnostic(diagnostics, "error", "invalid_camera_priority",
                    "camera_priority must be a number.", diag_context(elevator, controller))
            end
        end

        local landing_count = 0
        local stops = {}
        local room_seen = {}
        for _, node in ipairs(elevator.nodes or {}) do
            if node.node_id == "" then
                add_diagnostic(diagnostics, "error", "empty_node_id",
                    "Elevator nodes require a non-empty node_id.", diag_context(elevator, node))
            elseif elevator.nodes_by_id[node.node_id] then
                add_diagnostic(diagnostics, "error", "duplicate_node_id",
                    string.format("Elevator %q repeats node_id %q.", elevator_id, node.node_id),
                    diag_context(elevator, node))
            else
                elevator.nodes_by_id[node.node_id] = node
            end
            if node.kind ~= "landing" and node.kind ~= "pass_through" then
                add_diagnostic(diagnostics, "error", "invalid_node_kind",
                    string.format("Node %q has node_kind %q; use landing or pass_through.",
                        node.node_id, node.kind), diag_context(elevator, node))
            elseif node.kind == "landing" then
                landing_count = landing_count + 1
                if node.stop ~= "bottom" and node.stop ~= "top" then
                    add_diagnostic(diagnostics, "error", "invalid_landing_stop",
                        string.format("Landing node %q needs stop bottom or top.", node.node_id),
                        diag_context(elevator, node))
                elseif stops[node.stop] then
                    add_diagnostic(diagnostics, "error", "duplicate_landing_stop",
                        string.format("Elevator %q has more than one %s landing.", elevator_id, node.stop),
                        diag_context(elevator, node))
                else
                    stops[node.stop] = node
                end
            elseif node.stop ~= nil then
                add_diagnostic(diagnostics, "error", "pass_through_has_stop",
                    string.format("Pass-through node %q cannot claim stop %q.", node.node_id, node.stop),
                    diag_context(elevator, node))
            end
            if node.shape ~= "point" then
                add_diagnostic(diagnostics, "error", "node_not_point",
                    "Elevator nodes must be Tiled point objects.", diag_context(elevator, node))
            end
            if math.abs(node.rotation or 0) > 0.0001 then
                add_diagnostic(diagnostics, "error", "rotated_node",
                    "Elevator nodes cannot be rotated.", diag_context(elevator, node))
            end
            room_seen[node.room_id] = true
        end
        if landing_count < 2 then
            add_diagnostic(diagnostics, "error", "insufficient_landings",
                string.format("Elevator %q needs at least two landing nodes; found %d.",
                    elevator_id, landing_count), diag_context(elevator))
        end
        if not stops.bottom then
            add_diagnostic(diagnostics, "error", "missing_bottom_landing",
                string.format("Elevator %q needs one landing with stop=bottom.", elevator_id),
                diag_context(elevator))
        end
        if not stops.top then
            add_diagnostic(diagnostics, "error", "missing_top_landing",
                string.format("Elevator %q needs one landing with stop=top.", elevator_id),
                diag_context(elevator))
        end
        elevator.bottom_node = stops.bottom
        elevator.top_node = stops.top
        if stops.bottom and stops.top and stops.bottom.room_id == stops.top.room_id then
            add_diagnostic(diagnostics, "error", "landing_rooms_not_distinct",
                "Cross-room elevator bottom and top landings must be in different rooms.",
                diag_context(elevator, stops.top))
        end

        local start_node_id = elevator.controller and elevator.controller.start_node_id or ""
        local start_node = elevator.nodes_by_id[start_node_id]
        if start_node_id == "" then
            add_diagnostic(diagnostics, "error", "empty_start_node_id",
                "The elevator controller requires start_node_id.",
                diag_context(elevator, elevator.controller))
        elseif not start_node then
            add_diagnostic(diagnostics, "error", "missing_start_node",
                string.format("start_node_id %q does not match a node in elevator %q.",
                    start_node_id, elevator_id), diag_context(elevator, elevator.controller))
        elseif start_node.kind ~= "landing" then
            add_diagnostic(diagnostics, "error", "start_node_not_landing",
                "start_node_id must refer to a landing node, not a pass-through node.",
                diag_context(elevator, start_node))
        end
        for _, hidden_marker in ipairs(manifest.hidden_markers) do
            if hidden_marker.elevator_id == elevator_id then
                if hidden_marker.marker_kind == "controller" then
                    add_diagnostic(diagnostics, "warning", "hidden_controller_excluded",
                        string.format(
                            "Hidden elevator controller for %q is excluded; make it visible if it owns this route.",
                            elevator_id), diag_context(elevator, hidden_marker))
                else
                    add_diagnostic(diagnostics, "warning", "hidden_route_node_excluded",
                        string.format(
                            "Hidden elevator node %q is excluded from visible route %q.",
                            hidden_marker.node_id or "", elevator_id),
                        diag_context(elevator, hidden_marker))
                    if start_node_id ~= "" and hidden_marker.node_id == start_node_id
                        and start_node == nil
                    then
                        add_diagnostic(diagnostics, "error", "hidden_start_node_reference",
                            string.format(
                                "Visible elevator controller start_node_id %q refers to a hidden node; make the node visible or choose a visible landing.",
                                start_node_id), diag_context(elevator, hidden_marker))
                    end
                end
            end
        end
        elevator.start_node = start_node
        elevator.route = {
            start_node_id = start_node_id,
            bottom_node_id = stops.bottom and stops.bottom.node_id or nil,
            top_node_id = stops.top and stops.top.node_id or nil,
        }

        if elevator.controller then room_seen[elevator.controller.room_id] = true end
        for room_id in pairs(room_seen) do elevator.room_ids[#elevator.room_ids + 1] = room_id end
        table.sort(elevator.room_ids)
    end
    return diagnostics
end

local function sort_diagnostics(diagnostics)
    local severity_rank = { error = 1, warning = 2, info = 3 }
    table.sort(diagnostics, function(a, b)
        local ar = severity_rank[a.severity] or 9
        local br = severity_rank[b.severity] or 9
        if ar ~= br then return ar < br end
        local fields = { "elevator_id", "room_id", "object_id", "code", "message" }
        for _, field in ipairs(fields) do
            local av, bv = tostring(a[field] or ""), tostring(b[field] or "")
            if av ~= bv then return av < bv end
        end
        return false
    end)
end

local function finish(manifest, diagnostics)
    M.validate(manifest, diagnostics)
    sort_diagnostics(diagnostics)
    local errors, warnings = 0, 0
    local elevator_errors = {}
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.severity == "error" then
            errors = errors + 1
            if diagnostic.elevator_id then elevator_errors[diagnostic.elevator_id] = true end
        elseif diagnostic.severity == "warning" then
            warnings = warnings + 1
        end
    end
    for _, elevator_id in ipairs(manifest.ordered_ids or {}) do
        manifest.elevators[elevator_id].valid = not elevator_errors[elevator_id]
    end
    manifest.error_count = errors
    manifest.warning_count = warnings
    manifest.valid = errors == 0
    manifest.diagnostics = diagnostics
    return manifest, diagnostics
end

-- Build a single manifest from every room.  load_map(room_id) must return the
-- parsed Tiled Lua table and may optionally return its source path as value #2.
function M.build(room_ids, load_map, options)
    options = options or {}
    local manifest = {
        version = M.VERSION,
        elevators = {},
        hidden_markers = {},
        ordered_ids = {},
    }
    local diagnostics = {}
    if type(load_map) ~= "function" then
        add_diagnostic(diagnostics, "error", "missing_map_loader",
            "ElevatorManifest.build requires load_map(room_id).")
        return finish(manifest, diagnostics)
    end

    local ids = {}
    local seen_rooms = {}
    for _, value in ipairs(room_ids or {}) do
        local room_id = clean_room_id(value)
        if room_id == "" then
            add_diagnostic(diagnostics, "error", "empty_room_id", "Room ids cannot be empty.")
        elseif seen_rooms[room_id] then
            add_diagnostic(diagnostics, "error", "duplicate_room_id",
                "Room id appears more than once in elevator scan: " .. room_id, { room_id = room_id })
        else
            seen_rooms[room_id] = true
            ids[#ids + 1] = room_id
        end
    end
    table.sort(ids)

    local sources = {}
    for _, room_id in ipairs(ids) do
        local ok, map, source_or_error = pcall(load_map, room_id)
        if not ok then
            add_diagnostic(diagnostics, "error", "map_load_failed",
                "Failed to load Tiled export: " .. tostring(map), { room_id = room_id })
        elseif type(map) ~= "table" then
            add_diagnostic(diagnostics, "error", "map_load_failed",
                "Failed to load Tiled export: " .. tostring(source_or_error or "loader returned no map"),
                { room_id = room_id })
        else
            scan_map(manifest, diagnostics, room_id, map, source_or_error, options, sources)
        end
    end
    manifest.room_ids = ids
    return finish(manifest, diagnostics)
end

M.scan = M.build

function M.build_from_maps(maps, options)
    local room_ids = {}
    for room_id in pairs(maps or {}) do room_ids[#room_ids + 1] = room_id end
    return M.build(room_ids, function(room_id)
        return maps[room_id], "memory:" .. tostring(room_id)
    end, options)
end

return M
