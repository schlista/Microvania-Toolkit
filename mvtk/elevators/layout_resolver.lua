-- mvtk/elevators/layout_resolver.lua
--
-- Pure elevator layout resolution.  The authoring manifest stores coordinates
-- in each Tiled room's Defold-local space; this module applies the final room
-- collection origin, orders nodes, and validates every cross-room
-- shaft segment against the loaded room graph.  It has no Defold globals and
-- can run in standalone Lua tests.

local M = {}

M.VERSION = 1

local function trim(value)
    if value == nil then return "" end
    return tostring(value):match("^%s*(.-)%s*$") or ""
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

function M.normalize_room_id(room_id)
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

local function normalize_side(side)
    local value = trim(side):lower()
    if value == "top" or value == "north" then return "up" end
    if value == "bottom" or value == "south" then return "down" end
    if value == "east" then return "right" end
    if value == "west" then return "left" end
    return value
end

local function normalize_stop(stop)
    local value = trim(stop):lower():gsub("[%s%-]+", "_")
    if value == "bottom" or value == "lower" or value == "down" or value == "floor_1" then
        return "bottom"
    end
    if value == "top" or value == "upper" or value == "up" or value == "floor_2" then
        return "top"
    end
    return nil
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

local function diagnostic_context(elevator_id, marker, extra)
    local context = {
        elevator_id = elevator_id,
        room_id = marker and marker.room_id or nil,
        object_id = marker and marker.object_id or nil,
        source_key = marker and marker.source_key or nil,
        node_id = marker and marker.node_id or nil,
    }
    for key, value in pairs(extra or {}) do context[key] = value end
    return context
end

local function sorted_ids(values)
    local result = {}
    for key, value in pairs(values or {}) do
        if type(value) == "table" and type(key) == "string" then result[#result + 1] = key end
    end
    table.sort(result)
    return result
end

local function safe_call(owner, fn, argument)
    local ok, value = pcall(fn, argument)
    if ok then return value, nil end
    -- Support colon-style provider methods as well as RoomManager's dot-style
    -- functions without imposing either convention on callers.
    local method_ok, method_value = pcall(fn, owner, argument)
    if method_ok then return method_value, nil end
    return nil, tostring(value)
end

local function make_layout_access(layout, diagnostics)
    layout = layout or {}
    if type(layout.get_room_data) == "function" then
        return {
            room = function(room_id)
                local value, err = safe_call(layout, layout.get_room_data, room_id)
                if err then
                    add_diagnostic(diagnostics, "error", "room_provider_failed",
                        "get_room_data failed for " .. room_id .. ": " .. err, { room_id = room_id })
                end
                return value
            end,
            neighbors = function(room_id)
                if type(layout.get_room_neighbors) ~= "function" then return {} end
                local value, err = safe_call(layout, layout.get_room_neighbors, room_id)
                if err then
                    add_diagnostic(diagnostics, "error", "neighbor_provider_failed",
                        "get_room_neighbors failed for " .. room_id .. ": " .. err, { room_id = room_id })
                end
                return type(value) == "table" and value or {}
            end,
        }
    end

    local room_index = {}
    local rooms = layout.rooms or layout
    if type(rooms) == "table" then
        for key, room in pairs(rooms) do
            if type(room) == "table" then
                local room_id = M.normalize_room_id(room.id or (type(key) == "string" and key or ""))
                if room_id ~= "" then
                    if room_index[room_id] then
                        add_diagnostic(diagnostics, "error", "duplicate_layout_room",
                            "Layout repeats room id " .. room_id .. ".", { room_id = room_id })
                    else
                        room_index[room_id] = room
                    end
                end
            end
        end
    end
    return {
        room = function(room_id) return room_index[M.normalize_room_id(room_id)] end,
        neighbors = function(room_id)
            local room = room_index[M.normalize_room_id(room_id)]
            return room and room.neighbors or {}
        end,
    }
end

local function numeric(value, default)
    local result = tonumber(value)
    if result == nil then return default end
    return result
end

local function room_transform(access, room_id, cache, diagnostics, elevator_id, marker)
    room_id = M.normalize_room_id(room_id)
    if cache[room_id] ~= nil then
        return cache[room_id] or nil
    end
    local room = access.room(room_id)
    if type(room) ~= "table" then
        add_diagnostic(diagnostics, "error", "missing_layout_room",
            "Elevator marker references room " .. room_id .. ", but that room is absent from the final layout.",
            diagnostic_context(elevator_id, marker, { room_id = room_id }))
        cache[room_id] = false
        return nil
    end
    local transform = {
        id = room_id,
        x = numeric(room.x, 0),
        y = numeric(room.y, 0),
        ox = numeric(room.ox, 0),
        oy = numeric(room.oy, 0),
        w = numeric(room.w or room.width, 0),
        h = numeric(room.h or room.height, 0),
        source = room,
    }
    transform.base_x = transform.x + transform.ox
    transform.base_y = transform.y + transform.oy
    transform.collection_x, transform.collection_y =
        require("mvtk.map.streaming.room_geometry").compute_spawn_xy(room)
    cache[room_id] = transform
    return transform
end

local function resolve_node(elevator_id, node, access, room_cache, diagnostics)
    local room_id = M.normalize_room_id(node.room_id)
    local room = room_transform(access, room_id, room_cache, diagnostics, elevator_id, node)
    if not room then return nil end
    local local_x = tonumber(node.local_x)
    local local_y = tonumber(node.local_y)
    if not local_x or not local_y then
        add_diagnostic(diagnostics, "error", "invalid_node_coordinates",
            "Elevator node room-local coordinates must be numbers.",
            diagnostic_context(elevator_id, node, { room_id = room_id }))
        return nil
    end
    local result = copy(node)
    result.room_id = room_id
    result.local_x = local_x
    result.local_y = local_y
    result.world_x = room.collection_x + local_x
    result.world_y = room.collection_y + local_y
    result.kind = result.kind or result.node_kind or "landing"
    result.stop = normalize_stop(result.stop or (result.properties and result.properties.stop))
    result.door_id = trim(result.door_id or (result.properties and result.properties.door_id))
    result.runtime_stop = result.kind == "landing" and result.stop ~= nil
    return result
end

local function resolve_controller(elevator_id, controller, access, room_cache, diagnostics)
    if type(controller) ~= "table" then
        add_diagnostic(diagnostics, "error", "missing_controller",
            "Elevator manifest entry has no controller.", { elevator_id = elevator_id })
        return nil
    end
    local room_id = M.normalize_room_id(controller.room_id)
    local room = room_transform(access, room_id, room_cache, diagnostics, elevator_id, controller)
    if not room then return nil end
    local local_x = tonumber(controller.local_x)
    local local_y = tonumber(controller.local_y)
    local width = tonumber(controller.width)
    local height = tonumber(controller.height)
    if not local_x or not local_y or not width or not height or width <= 0 or height <= 0 then
        add_diagnostic(diagnostics, "error", "invalid_controller_geometry",
            "Elevator controller needs numeric room-local position and positive width/height.",
            diagnostic_context(elevator_id, controller, { room_id = room_id }))
        return nil
    end
    local result = copy(controller)
    result.room_id = room_id
    result.local_x = local_x
    result.local_y = local_y
    result.width = width
    result.height = height
    result.world_x = room.collection_x + local_x
    result.world_y = room.collection_y + local_y
    result.world_center_x = result.world_x + width * 0.5
    return result
end

local function node_sort(a, b)
    if a.world_y ~= b.world_y then return a.world_y < b.world_y end
    if a.world_x ~= b.world_x then return a.world_x < b.world_x end
    if tostring(a.node_id) ~= tostring(b.node_id) then
        return tostring(a.node_id) < tostring(b.node_id)
    end
    return tostring(a.source_key or "") < tostring(b.source_key or "")
end

local function edge_target(edge)
    return M.normalize_room_id(edge and (edge.id or edge.room_id or edge.target_id) or "")
end

local function find_edge(neighbors, target_room_id, shaft_x, source_room)
    target_room_id = M.normalize_room_id(target_room_id)
    local best, best_score = nil, math.huge
    for _, edge in ipairs(neighbors or {}) do
        if type(edge) == "table" and edge_target(edge) == target_room_id then
            if not shaft_x or not source_room then return edge end
            local cx = edge.door and tonumber(edge.door.cx or edge.door.x)
            local score = cx and math.abs((source_room.base_x + cx) - shaft_x) or math.huge
            if not best or score < best_score then
                best, best_score = edge, score
            end
        end
    end
    return best
end

local function opening_world_x(opening, room)
    if type(opening) ~= "table" or not room then return nil end
    local cx = tonumber(opening.cx or opening.x)
    if not cx then return nil end
    return room.base_x + cx
end


local function opening_world_y(opening, room)
    if type(opening) ~= "table" or not room then return nil end
    local cy = tonumber(opening.cy or opening.y)
    if not cy then return nil end
    return room.base_y + cy
end

local function validate_openings(elevator, segment, edge, reciprocal, room_cache, diagnostics, options)
    local lower_room = room_cache[segment.from_room_id]
    local upper_room = room_cache[segment.to_room_id]
    local lower_opening = edge and (edge.door or (reciprocal and reciprocal.mate)) or nil
    local upper_opening = edge and (edge.mate or (reciprocal and reciprocal.door)) or nil
    segment.lower_opening = copy(lower_opening)
    segment.upper_opening = copy(upper_opening)

    local context = {
        elevator_id = elevator.id,
        from_room_id = segment.from_room_id,
        to_room_id = segment.to_room_id,
        from_node_id = segment.from_node_id,
        to_node_id = segment.to_node_id,
    }
    if type(lower_opening) ~= "table" or type(upper_opening) ~= "table" then
        add_diagnostic(diagnostics, options.require_door_hints and "error" or "warning",
            "missing_door_hint",
            "Cross-room elevator edge has no complete door/mate metadata; shaft opening alignment cannot be proven.",
            context)
        return
    end

    local lower_x = opening_world_x(lower_opening, lower_room)
    local upper_x = opening_world_x(upper_opening, upper_room)
    local tolerance = math.abs(numeric(options.door_x_tolerance, options.x_tolerance))
    if not lower_x or not upper_x then
        add_diagnostic(diagnostics, "error", "invalid_door_hint",
            "Elevator door/mate hints require numeric cx values.", context)
        return
    end
    segment.lower_opening_world_x = lower_x
    segment.upper_opening_world_x = upper_x
    local lower_y = opening_world_y(lower_opening, lower_room)
    local upper_y = opening_world_y(upper_opening, upper_room)
    if lower_y and upper_y then
        local y_tolerance = math.abs(numeric(options.door_y_tolerance, options.y_tolerance))
        segment.lower_opening_world_y = lower_y
        segment.upper_opening_world_y = upper_y
        segment.seam_y = (lower_y + upper_y) * 0.5
        if math.abs(lower_y - upper_y) > y_tolerance then
            add_diagnostic(diagnostics, "error", "door_pair_vertical_mismatch",
                string.format("Elevator door pair differs by %.3f px in world Y (tolerance %.3f).",
                    math.abs(lower_y - upper_y), y_tolerance), context)
        end
    end
    if math.abs(lower_x - upper_x) > tolerance then
        add_diagnostic(diagnostics, "error", "door_pair_misaligned",
            string.format("Elevator door pair differs by %.3f px in world X (tolerance %.3f).",
                math.abs(lower_x - upper_x), tolerance), context)
    end
    if math.abs(lower_x - elevator.shaft_x) > tolerance
        or math.abs(upper_x - elevator.shaft_x) > tolerance
    then
        add_diagnostic(diagnostics, "error", "shaft_door_misaligned",
            string.format("Door pair is not centered on elevator shaft X %.3f.", elevator.shaft_x), context)
    end

    local required_width = (elevator.controller and elevator.controller.width or 0)
        + 2 * math.max(0, numeric(elevator.settings.shaft_clearance, 0))
    for label, opening in pairs({ lower = lower_opening, upper = upper_opening }) do
        local opening_width = tonumber(opening.len or opening.len_px)
        if opening_width and opening_width > 0 and opening_width + tolerance < required_width then
            add_diagnostic(diagnostics, "error", "shaft_opening_too_narrow",
                string.format("%s shaft opening is %.3f px; cabin plus clearance needs %.3f px.",
                    label, opening_width, required_width), context)
        end
    end
end

local function validate_cross_room_segment(elevator, segment, access, room_cache, diagnostics, options)
    if options.validate_neighbors == false then return end
    local lower_neighbors = access.neighbors(segment.from_room_id)
    local edge = find_edge(lower_neighbors, segment.to_room_id, elevator.shaft_x,
        room_cache[segment.from_room_id])
    local context = {
        elevator_id = elevator.id,
        from_room_id = segment.from_room_id,
        to_room_id = segment.to_room_id,
        from_node_id = segment.from_node_id,
        to_node_id = segment.to_node_id,
    }
    if not edge then
        add_diagnostic(diagnostics, "error", "missing_neighbor_edge",
            "Consecutive elevator nodes in different rooms must use a direct room-neighbor edge.", context)
        return
    end
    segment.neighbor = copy(edge)
    if normalize_side(edge.side or (edge.door and edge.door.side)) ~= "up" then
        add_diagnostic(diagnostics, "error", "non_vertical_neighbor_edge",
            "The lower room must connect to the upper room through its up edge.", context)
    end

    local reciprocal = find_edge(access.neighbors(segment.to_room_id), segment.from_room_id,
        elevator.shaft_x, room_cache[segment.to_room_id])
    segment.reciprocal_neighbor = copy(reciprocal)
    if not reciprocal then
        add_diagnostic(diagnostics, options.require_reciprocal == false and "warning" or "error",
            "missing_reciprocal_neighbor",
            "Elevator room-neighbor edges must be reciprocal.", context)
    elseif normalize_side(reciprocal.side or (reciprocal.door and reciprocal.door.side)) ~= "down" then
        add_diagnostic(diagnostics, "error", "non_reciprocal_neighbor_side",
            "The upper room's reciprocal elevator edge must point down.", context)
    end
    validate_openings(elevator, segment, edge, reciprocal, room_cache, diagnostics, options)
end

local function resolve_elevator(authored, access, room_cache, diagnostics, options)
    local elevator_id = trim(authored.id or authored.elevator_id)
    local before_errors = 0
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.severity == "error" and diagnostic.elevator_id == elevator_id then
            before_errors = before_errors + 1
        end
    end
    local elevator = {
        id = elevator_id,
        resource_key = authored.resource_key,
        settings = copy(authored.settings
            or (authored.controller and authored.controller.properties)
            or {}),
        nodes = {},
        nodes_by_id = {},
        landings = {},
        segments = {},
        room_ids = {},
        cross_room_segments = {},
    }
    if elevator_id == "" then
        add_diagnostic(diagnostics, "error", "empty_elevator_id",
            "Resolved elevator entries require an id.")
    end
    if authored.valid == false then
        add_diagnostic(diagnostics, "error", "invalid_manifest_entry",
            "Elevator manifest structural validation failed before layout resolution.",
            { elevator_id = elevator_id })
    end

    elevator.controller = resolve_controller(elevator_id,
        authored.controller or (authored.controllers and authored.controllers[1]),
        access, room_cache, diagnostics)

    for _, authored_node in ipairs(authored.nodes or {}) do
        local node = resolve_node(elevator_id, authored_node, access, room_cache, diagnostics)
        if node then elevator.nodes[#elevator.nodes + 1] = node end
    end
    table.sort(elevator.nodes, node_sort)

    if #elevator.nodes < 2 then
        add_diagnostic(diagnostics, "error", "insufficient_nodes",
            "An elevator route needs at least two resolved nodes.", { elevator_id = elevator_id })
    end

    local start_node_id = trim((elevator.controller and elevator.controller.start_node_id)
        or (authored.controller and authored.controller.start_node_id)
        or (authored.controller and authored.controller.properties
            and authored.controller.properties.start_node_id))
    local stop_nodes = {}
    for index, node in ipairs(elevator.nodes) do
        node.order = index
        if node.node_id and node.node_id ~= "" then
            if elevator.nodes_by_id[node.node_id] then
                add_diagnostic(diagnostics, "error", "duplicate_node_id",
                    "Elevator route repeats node_id " .. tostring(node.node_id) .. ".",
                    diagnostic_context(elevator_id, node))
            else
                elevator.nodes_by_id[node.node_id] = node
            end
        end
        if node.kind == "landing" then
            elevator.landings[#elevator.landings + 1] = node
            if not node.stop then
                add_diagnostic(diagnostics, "error", "invalid_landing_stop",
                    "Landing nodes must resolve to stop bottom or top.",
                    diagnostic_context(elevator_id, node))
            elseif stop_nodes[node.stop] then
                add_diagnostic(diagnostics, "error", "duplicate_landing_stop",
                    "Elevator route repeats landing stop " .. node.stop .. ".",
                    diagnostic_context(elevator_id, node))
            else
                stop_nodes[node.stop] = node
            end
        elseif node.stop then
            add_diagnostic(diagnostics, "error", "pass_through_has_stop",
                "Pass-through nodes cannot be runtime bottom/top stops.",
                diagnostic_context(elevator_id, node))
        end
    end
    elevator.bottom_node = stop_nodes.bottom
    elevator.top_node = stop_nodes.top
    if elevator.bottom_node and elevator.top_node
        and elevator.bottom_node.room_id == elevator.top_node.room_id
    then
        add_diagnostic(diagnostics, "error", "landing_rooms_not_distinct",
            "Cross-room elevator bottom and top landings must resolve to different rooms.",
            diagnostic_context(elevator_id, elevator.top_node))
    end
    elevator.start_node = elevator.nodes_by_id[start_node_id]
    if start_node_id == "" or not elevator.start_node then
        add_diagnostic(diagnostics, "error", "missing_start_node",
            "Controller start_node_id does not resolve to an elevator node.", { elevator_id = elevator_id })
    elseif elevator.start_node.kind ~= "landing" or not elevator.start_node.stop then
        add_diagnostic(diagnostics, "error", "start_node_not_landing",
            "Controller start_node_id must resolve to a bottom/top landing.",
            diagnostic_context(elevator_id, elevator.start_node))
    end

    elevator.shaft_x = elevator.start_node and elevator.start_node.world_x
        or (elevator.controller and elevator.controller.world_center_x)
    local x_tolerance = math.abs(numeric(options.x_tolerance,
        numeric(elevator.settings.shaft_tolerance, 0.5)))
    local y_tolerance = math.abs(numeric(options.y_tolerance, 1))
    if elevator.shaft_x then
        if elevator.controller
            and math.abs(elevator.controller.world_center_x - elevator.shaft_x) > x_tolerance
        then
            add_diagnostic(diagnostics, "error", "controller_shaft_misaligned",
                string.format("Cabin center differs from shaft X by %.3f px.",
                    math.abs(elevator.controller.world_center_x - elevator.shaft_x)),
                diagnostic_context(elevator_id, elevator.controller))
        end
        for _, node in ipairs(elevator.nodes) do
            if math.abs(node.world_x - elevator.shaft_x) > x_tolerance then
                add_diagnostic(diagnostics, "error", "node_shaft_misaligned",
                    string.format("Node %q differs from shaft X by %.3f px.",
                        tostring(node.node_id), math.abs(node.world_x - elevator.shaft_x)),
                    diagnostic_context(elevator_id, node))
            end
        end
    end

    if elevator.controller and elevator.start_node then
        if elevator.controller.room_id ~= elevator.start_node.room_id then
            add_diagnostic(diagnostics, "error", "start_room_mismatch",
                "The cabin controller and its start node must be authored in the same room.",
                diagnostic_context(elevator_id, elevator.start_node))
        end
        local floor_offset = numeric(elevator.settings.floor_offset, elevator.controller.height)
        elevator.controller.world_floor_y = elevator.controller.world_y + floor_offset
        if math.abs(elevator.controller.world_floor_y - elevator.start_node.world_y) > y_tolerance then
            add_diagnostic(diagnostics, "error", "start_surface_mismatch",
                string.format("Cabin floor differs from start node Y by %.3f px.",
                    math.abs(elevator.controller.world_floor_y - elevator.start_node.world_y)),
                diagnostic_context(elevator_id, elevator.start_node))
        end
    end

    if elevator.nodes[1] and elevator.nodes[1] ~= elevator.bottom_node then
        add_diagnostic(diagnostics, "error", "bottom_stop_not_lowest",
            "The node with stop=bottom must be the lowest elevator node.",
            diagnostic_context(elevator_id, elevator.nodes[1]))
    end
    if elevator.nodes[#elevator.nodes] and elevator.nodes[#elevator.nodes] ~= elevator.top_node then
        add_diagnostic(diagnostics, "error", "top_stop_not_highest",
            "The node with stop=top must be the highest elevator node.",
            diagnostic_context(elevator_id, elevator.nodes[#elevator.nodes]))
    end

    local room_seen, room_closed, previous_room = {}, {}, nil
    for index, node in ipairs(elevator.nodes) do
        if previous_room and previous_room ~= node.room_id then room_closed[previous_room] = true end
        if room_closed[node.room_id] then
            add_diagnostic(diagnostics, "error", "room_reentry",
                "Vertical node order leaves and then re-enters room " .. node.room_id .. ".",
                diagnostic_context(elevator_id, node))
        end
        if not room_seen[node.room_id] then
            room_seen[node.room_id] = true
            elevator.room_ids[#elevator.room_ids + 1] = node.room_id
        end
        previous_room = node.room_id

        local next_node = elevator.nodes[index + 1]
        if next_node then
            if next_node.world_y - node.world_y <= y_tolerance then
                add_diagnostic(diagnostics, "error", "node_vertical_overlap",
                    string.format("Nodes %q and %q need distinct increasing world Y positions.",
                        tostring(node.node_id), tostring(next_node.node_id)),
                    diagnostic_context(elevator_id, next_node))
            end
            local segment = {
                index = index,
                key = tostring(elevator.resource_key or elevator.id) .. ":segment:"
                    .. tostring(node.node_id) .. ":" .. tostring(next_node.node_id),
                from_node_id = node.node_id,
                to_node_id = next_node.node_id,
                from_room_id = node.room_id,
                to_room_id = next_node.room_id,
                from_y = node.world_y,
                to_y = next_node.world_y,
                distance = next_node.world_y - node.world_y,
                crosses_room = node.room_id ~= next_node.room_id,
                seam_y = (node.world_y + next_node.world_y) * 0.5,
            }
            elevator.segments[#elevator.segments + 1] = segment
            if segment.crosses_room then
                elevator.cross_room_segments[#elevator.cross_room_segments + 1] = segment
                local segment_options = copy(options)
                segment_options.x_tolerance = math.abs(numeric(options.x_tolerance,
                    numeric(elevator.settings.shaft_tolerance, 0.5)))
                segment_options.y_tolerance = math.abs(numeric(options.y_tolerance, 1))
                validate_cross_room_segment(elevator, segment, access, room_cache, diagnostics,
                    segment_options)
            end
        end
    end
    elevator.min_y = elevator.nodes[1] and elevator.nodes[1].world_y or nil
    elevator.max_y = elevator.nodes[#elevator.nodes] and elevator.nodes[#elevator.nodes].world_y or nil

    local ordered_route_nodes = {}
    for _, node in ipairs(elevator.nodes) do
        ordered_route_nodes[#ordered_route_nodes + 1] = {
            node_id = node.node_id,
            kind = node.kind,
            stop = node.stop,
            runtime_stop = node.runtime_stop,
            door_id = node.door_id,
            room_id = node.room_id,
            source_key = node.source_key,
            local_x = node.local_x,
            local_y = node.local_y,
            world_x = node.world_x,
            world_y = node.world_y,
            order = node.order,
        }
    end
    elevator.route = {
        start_node_id = elevator.start_node and elevator.start_node.node_id or start_node_id,
        bottom_node_id = elevator.bottom_node and elevator.bottom_node.node_id or nil,
        top_node_id = elevator.top_node and elevator.top_node.node_id or nil,
        ordered_nodes = ordered_route_nodes,
        segment_count = #elevator.segments,
        cross_room_segment_count = #elevator.cross_room_segments,
    }
    elevator.runtime_v1_compatible = elevator.bottom_node ~= nil and elevator.top_node ~= nil
    if elevator.bottom_node and elevator.top_node then
        local cabin_width = elevator.controller and elevator.controller.width or 0
        local cabin_height = elevator.controller and elevator.controller.height or 0
        local floor_offset = numeric(elevator.settings.floor_offset, cabin_height)
        local root_x = elevator.shaft_x - cabin_width * 0.5
        local visual_z = numeric(elevator.settings.visual_z, 0)
        local handoff_points = {}
        for _, segment in ipairs(elevator.cross_room_segments) do
            handoff_points[#handoff_points + 1] = {
                -- ElevatorState moves the persistent cabin GO's bottom-left
                -- origin; authored nodes and door hints describe its floor.
                y = segment.seam_y - floor_offset,
                from_room_id = segment.from_room_id,
                to_room_id = segment.to_room_id,
            }
        end
        local seam_y = (#handoff_points == 1) and handoff_points[1].y
            or (((elevator.bottom_node.world_y - floor_offset)
                + (elevator.top_node.world_y - floor_offset)) * 0.5)
        elevator.state_config = {
            bottom = {
                x = root_x,
                y = elevator.bottom_node.world_y - floor_offset,
                z = visual_z,
            },
            top = {
                x = root_x,
                y = elevator.top_node.world_y - floor_offset,
                z = visual_z,
            },
            home_stop = elevator.start_node and elevator.start_node.stop or "bottom",
            speed = numeric(elevator.settings.speed, 96),
            acceleration = numeric(elevator.settings.acceleration, 384),
            deceleration = numeric(elevator.settings.deceleration, 384),
            start_delay = numeric(elevator.settings.start_delay, 0),
            endpoint_wait = numeric(elevator.settings.endpoint_wait, 0.35),
            close_time = numeric(elevator.settings.close_time, 0.25),
            open_time = numeric(elevator.settings.open_time, 0.25),
            ready_timeout = numeric(elevator.settings.ready_timeout, 5),
            shaft_tolerance = numeric(elevator.settings.shaft_tolerance, 0.5),
            seam_y = seam_y,
            handoff_points = #handoff_points > 0 and handoff_points or nil,
        }

        local runtime_nodes = {}
        for _, node in ipairs(ordered_route_nodes) do
            runtime_nodes[#runtime_nodes + 1] = {
                node_id = node.node_id,
                node_kind = node.kind,
                kind = node.kind,
                stop = node.stop,
                door_id = node.door_id,
                room_id = node.room_id,
                order = node.order,
                position = { x = root_x, y = node.world_y - floor_offset, z = visual_z },
                local_position = { x = node.local_x, y = node.local_y, z = 0 },
            }
        end
        elevator.runtime_definition = {
            id = elevator.id,
            elevator_id = elevator.id,
            cabin_resource_key = elevator.resource_key,
            settings = copy(elevator.settings),
            home_stop = elevator.state_config.home_stop,
            width = cabin_width,
            height = cabin_height,
            bottom = runtime_nodes[1],
            top = runtime_nodes[#runtime_nodes],
            route_nodes = runtime_nodes,
            route_room_ids = copy(elevator.room_ids),
            handoff_points = copy(elevator.state_config.handoff_points),
        }
    end
    elevator.camera_config = {
        follow = elevator.settings.camera_follow ~= false,
        lock_x = elevator.settings.camera_lock_x ~= false,
        look_ahead = numeric(elevator.settings.camera_look_ahead, 96),
        blend_time = numeric(elevator.settings.camera_blend_time, 0.2),
        priority = numeric(elevator.settings.camera_priority, 50),
    }

    local after_errors = 0
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.severity == "error" and diagnostic.elevator_id == elevator_id then
            after_errors = after_errors + 1
        end
    end
    elevator.valid = after_errors == before_errors
    return elevator
end

local function sort_diagnostics(diagnostics)
    local severity_rank = { error = 1, warning = 2, info = 3 }
    table.sort(diagnostics, function(a, b)
        local ar, br = severity_rank[a.severity] or 9, severity_rank[b.severity] or 9
        if ar ~= br then return ar < br end
        local fields = {
            "elevator_id", "from_room_id", "to_room_id", "room_id",
            "node_id", "object_id", "code", "message",
        }
        for _, field in ipairs(fields) do
            local av, bv = tostring(a[field] or ""), tostring(b[field] or "")
            if av ~= bv then return av < bv end
        end
        return false
    end)
end

-- layout_or_provider may be the generated { rooms = {...} } layout or a
-- RoomManager-like table exposing get_room_data/get_room_neighbors.  Passing
-- the latter after RoomManager.load_layout() ensures rebuilt runtime positions
-- are authoritative.
function M.resolve(manifest, layout_or_provider, options)
    options = options or {}
    local diagnostics = {}
    local access = make_layout_access(layout_or_provider, diagnostics)
    local room_cache = {}
    local authored_elevators = manifest and manifest.elevators or {}
    local ordered_ids = {}
    for _, elevator_id in ipairs((manifest and manifest.ordered_ids) or {}) do
        if authored_elevators[elevator_id] then ordered_ids[#ordered_ids + 1] = elevator_id end
    end
    if #ordered_ids == 0 then ordered_ids = sorted_ids(authored_elevators) end

    local resolved = {
        version = M.VERSION,
        manifest_version = manifest and manifest.version or nil,
        elevators = {},
        ordered_ids = ordered_ids,
        room_to_elevators = {},
    }
    for _, elevator_id in ipairs(ordered_ids) do
        local elevator = resolve_elevator(authored_elevators[elevator_id], access, room_cache,
            diagnostics, options)
        resolved.elevators[elevator_id] = elevator
        for _, room_id in ipairs(elevator.room_ids) do
            local list = resolved.room_to_elevators[room_id]
            if not list then
                list = {}
                resolved.room_to_elevators[room_id] = list
            end
            list[#list + 1] = elevator_id
        end
    end
    for _, elevator_ids in pairs(resolved.room_to_elevators) do table.sort(elevator_ids) end

    sort_diagnostics(diagnostics)
    local errors, warnings = 0, 0
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.severity == "error" then errors = errors + 1 end
        if diagnostic.severity == "warning" then warnings = warnings + 1 end
    end
    resolved.error_count = errors
    resolved.warning_count = warnings
    resolved.valid = errors == 0
    resolved.diagnostics = diagnostics
    return resolved, diagnostics
end

return M
