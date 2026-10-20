-- mvtk/elevators/elevator_manager.lua
-- Persistent registry/coordinator for elevators that cross streamed rooms.
--
-- The module is intentionally world-owned: streamed controller/node game
-- objects register authored metadata, but unloading those objects does not
-- erase the definition or the active cabin.  A persistent cabin game object
-- calls update() and owns TriggerBus registration/passenger collision.

local State = require "mvtk.elevators.elevator_state"
local Contract = require "mvtk.elevators.elevator_contract"
local Identity = require "mvtk.elevators.elevator_identity"
local DefaultPersistence = require "mvtk.elevators.elevator_persistence"
local LayoutResolver = require "mvtk.elevators.layout_resolver"
local Util = require "mvtk.core.util"

local M = {}

local records = {}
local adapters = {}
local world_generation = 1
local registration_serial = 0
local attachment_serial = 0

local RoomManager = nil
local Constants = nil

local function finite_number(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    return n
end

local function normalize_id(value)
    local normalized = Util.normalize_hash_string(value, {
        keep_unknown = true,
        unknown_as_value = true,
        prefer_hex = true,
    })
    if normalized == nil then return nil end
    if type(normalized) ~= "string" then
        normalized = tostring(normalized)
    end
    if normalized == "" or normalized == "0000000000000000" then
        return nil
    end
    return normalized
end

local function normalize_room_id(value)
    local normalized = Util.normalize_room_id(value)
    if normalized == "" then return nil end
    return normalized
end

local function normalize_stop(value)
    return State.normalize_stop(value)
end

local function copy_position(position)
    position = position or {}
    return {
        x = finite_number(position.x) or 0,
        y = finite_number(position.y) or 0,
        z = finite_number(position.z) or 0,
    }
end

local function to_engine_position(position)
    if vmath and vmath.vector3 then
        return vmath.vector3(position.x or 0, position.y or 0, position.z or 0)
    end
    return copy_position(position)
end

local function safe_hash(value)
    if type(hash) == "function" then return hash(value) end
    return value
end

local function safe_post(url, message_id, payload)
    if not url or not msg or type(msg.post) ~= "function" then
        return false
    end
    local ok = pcall(msg.post, url, safe_hash(message_id), payload or {})
    return ok
end

local function object_url(url)
    if not url or not msg or type(msg.url) ~= "function" then return url end
    local ok, parsed = pcall(msg.url, url)
    if not ok or not parsed then return url end
    local ok_go, result = pcall(msg.url, parsed.socket, parsed.path, nil)
    return ok_go and result or url
end

local function get_room_manager()
    if RoomManager ~= nil then
        return RoomManager ~= false and RoomManager or nil
    end
    local ok, manager = pcall(require, "mvtk.map.streaming.room_manager")
    RoomManager = ok and manager or false
    return RoomManager ~= false and RoomManager or nil
end

local function get_constants()
    if Constants ~= nil then
        return Constants ~= false and Constants or nil
    end
    local ok, constants = pcall(require, "mvtk.core.constants")
    Constants = ok and constants or false
    return Constants ~= false and Constants or nil
end

local function persistence_adapter()
    if type(adapters.persistence) == "table" then return adapters.persistence end
    return DefaultPersistence
end

local function make_record(key, authored_id)
    return {
        key = key,
        id = authored_id or tostring(key),
        world_generation = world_generation,
        enabled = true,
        controller = {},
        controller_canonical = false,
        controller_live = nil,
        nodes = {},
        route_nodes = {},
        route_room_ids = {},
        handoff_points = {},
        machine = nil,
        machine_fingerprint = nil,
        definition_error = nil,
        cabin_url = nil,
        cabin_owner_url = nil,
        attachment_token = nil,
        spawn_pending = false,
        spawn_generation = nil,
        room_token = nil,
        camera_token = nil,
        active_generation = nil,
        queued_stop = nil,
        active_route = nil,
        active_route_index = nil,
    }
end

local function get_or_create(key, authored_id)
    local record = records[key]
    if not record then
        record = make_record(key, authored_id)
        records[key] = record
    elseif authored_id then
        -- The generated global index owns the human-readable authored id. A
        -- streamed marker can arrive first, but must not permanently replace
        -- diagnostics/resource names with an opaque release hash.
        record.id = authored_id
    end
    return record
end

local function merge_controller(target, source)
    local fields = {
        "trigger_id", "cabin_resource_key", "home_stop", "speed",
        "close_time", "open_time", "ready_timeout", "seam_y",
        "seam_y_authored", "camera_priority", "enabled", "width",
        "height", "carry_player", "camera_url", "player_url",
        -- Canonical grouped Tiled settings.  Keeping these on the runtime
        -- definition prevents the manifest scanner's authored controls from
        -- being silently discarded.
        "acceleration", "deceleration", "endpoint_wait", "start_delay",
        "route_mode", "activation_mode", "require_interact", "floor_offset",
        "co_y_offset", "sensor_y_offset", "carry_enemies", "carry_pushables",
        "require_rider", "shaft_clearance", "shaft_tolerance",
        "camera_follow", "camera_lock_x", "camera_look_ahead",
        "camera_blend_time", "persist_landing", "restore_to_last_landing",
    }
    for _, field in ipairs(fields) do
        if source[field] ~= nil then
            target[field] = source[field]
        end
    end

    target.trigger_id = normalize_id(target.trigger_id)
    target.cabin_resource_key = normalize_id(target.cabin_resource_key)
    target.home_stop = normalize_stop(target.home_stop) or State.STOP_BOTTOM
    if source.enabled ~= nil then
        target.enabled = source.enabled ~= false
    elseif target.enabled == nil then
        target.enabled = true
    end
end

local function resolve_local_position(room_id, local_position)
    if not local_position then return nil end
    local manager = get_room_manager()
    if not manager or not manager.get_room_data then return nil end
    local ok, room = pcall(manager.get_room_data, room_id)
    if not ok or not room then return nil end
    local x, y = require("mvtk.map.streaming.room_geometry").compute_spawn_xy(room)
    return {
        x = x + (finite_number(local_position.x) or 0),
        y = y + (finite_number(local_position.y) or 0),
        z = finite_number(local_position.z) or 0,
    }
end

local function normalize_node(definition)
    local kind = tostring(definition.kind or definition.node_kind or "landing"):lower()
        :gsub("[%s%-]+", "_")
    if kind == "passthrough" then kind = "pass_through" end
    local stop = normalize_stop(definition.stop)
    if not stop then
        -- Older marker drafts used node_kind=bottom/top.  Accept that alias,
        -- while the current manifest uses node_kind=landing/pass_through.
        stop = normalize_stop(definition.node_kind)
    end
    if kind ~= "landing" and kind ~= "pass_through" then
        return nil, "node_kind must be 'landing' or 'pass_through'"
    end
    if kind == "pass_through" then stop = nil end
    local room_id = normalize_room_id(definition.room_id)
    if not room_id then return nil, "node requires room_id" end
    local position = definition.position and copy_position(definition.position)
        or resolve_local_position(room_id, definition.local_position)
    if not position then return nil, "node requires a world position (or resolvable local_position)" end

    return {
        elevator_id = normalize_id(definition.elevator_id or definition.id),
        node_id = normalize_id(definition.node_id),
        registry_key = Identity.node_key(definition.node_id),
        kind = kind,
        node_kind = kind,
        stop = stop,
        room_id = room_id,
        door_id = normalize_id(definition.door_id),
        position = position,
        local_position = definition.local_position and copy_position(definition.local_position) or nil,
        url = definition.url,
        registration = definition.registration,
        order = finite_number(definition.order),
        canonical = definition.canonical == true,
    }
end

local function route_node_key(node)
    return node.registry_key or node.node_id or table.concat({
        tostring(node.room_id), tostring(node.kind), tostring(node.position.x), tostring(node.position.y),
    }, ":")
end

local function rebuild_route(record)
    local ordered = {}
    for _, node in pairs(record.route_nodes or {}) do ordered[#ordered + 1] = node end
    table.sort(ordered, function(a, b)
        if a.position.y ~= b.position.y then return a.position.y < b.position.y end
        if (a.order or math.huge) ~= (b.order or math.huge) then
            return (a.order or math.huge) < (b.order or math.huge)
        end
        return tostring(a.node_id or "") < tostring(b.node_id or "")
    end)

    local landings = {}
    for _, node in ipairs(ordered) do
        if node.kind == "landing" then landings[#landings + 1] = node end
    end
    if #landings >= 2 then
        -- Endpoint order is authoritative even when old content omitted stop.
        landings[1].stop = State.STOP_BOTTOM
        landings[#landings].stop = State.STOP_TOP
        record.nodes[State.STOP_BOTTOM] = landings[1]
        record.nodes[State.STOP_TOP] = landings[#landings]
    end

    record.route_room_ids = {}
    record.handoff_points = {}
    local previous_room, previous_node = nil, nil
    for _, node in ipairs(ordered) do
        if node.room_id ~= previous_room then
            record.route_room_ids[#record.route_room_ids + 1] = node.room_id
            if previous_node then
                record.handoff_points[#record.handoff_points + 1] = {
                    y = (previous_node.position.y + node.position.y) * 0.5,
                    from_room_id = previous_room,
                    to_room_id = node.room_id,
                }
            end
            previous_room = node.room_id
        end
        previous_node = node
    end

    record.route_nodes_ordered = ordered
end

local function definition_view(record)
    local controller = record.controller or {}
    local bottom = record.nodes[State.STOP_BOTTOM]
    local top = record.nodes[State.STOP_TOP]
    return {
        id = record.id,
        elevator_id = record.id,
        trigger_id = controller.trigger_id or record.id,
        cabin_resource_key = controller.cabin_resource_key or record.id,
        home_stop = controller.home_stop or State.STOP_BOTTOM,
        speed = finite_number(controller.speed) or 96,
        acceleration = finite_number(controller.acceleration) or 0,
        deceleration = finite_number(controller.deceleration) or 0,
        endpoint_wait = finite_number(controller.endpoint_wait) or 0,
        start_delay = finite_number(controller.start_delay) or 0,
        close_time = finite_number(controller.close_time) or 0.25,
        open_time = finite_number(controller.open_time) or 0.25,
        ready_timeout = finite_number(controller.ready_timeout) or 5,
        seam_y = controller.seam_y,
        seam_y_authored = controller.seam_y_authored == true,
        camera_priority = finite_number(controller.camera_priority) or 50,
        route_mode = normalize_id(controller.route_mode) or "pingpong",
        activation_mode = normalize_id(controller.activation_mode) or "on_board",
        require_interact = controller.require_interact == true,
        width = finite_number(controller.width) or 128,
        height = finite_number(controller.height) or 32,
        carry_player = controller.carry_player ~= false,
        carry_enemies = controller.carry_enemies == true,
        carry_pushables = controller.carry_pushables ~= false,
        require_rider = controller.require_rider ~= false,
        floor_offset = finite_number(controller.floor_offset) or (finite_number(controller.height) or 32),
        enabled = record.enabled ~= false and controller.enabled ~= false,
        camera_url = controller.camera_url,
        player_url = controller.player_url,
        camera_follow = controller.camera_follow ~= false,
        camera_lock_x = controller.camera_lock_x ~= false,
        camera_look_ahead = finite_number(controller.camera_look_ahead) or 96,
        camera_blend_time = finite_number(controller.camera_blend_time) or 0.2,
        persist_landing = controller.persist_landing == true,
        restore_to_last_landing = controller.restore_to_last_landing == true,
        bottom = bottom,
        top = top,
        bottom_room_id = bottom and bottom.room_id or nil,
        top_room_id = top and top.room_id or nil,
        world_generation = record.world_generation,
        route_room_ids = record.route_room_ids,
        handoff_points = record.handoff_points,
        route_nodes = record.route_nodes_ordered,
    }
end

local function config_fingerprint(definition)
    if not definition.bottom or not definition.top then return nil end
    local seam = definition.seam_y_authored and finite_number(definition.seam_y) or nil
    local parts = {
        tostring(definition.bottom.position.x), tostring(definition.bottom.position.y), tostring(definition.bottom.position.z),
        tostring(definition.top.position.x), tostring(definition.top.position.y), tostring(definition.top.position.z),
        tostring(definition.bottom.room_id), tostring(definition.top.room_id),
        tostring(definition.home_stop), tostring(definition.speed), tostring(definition.close_time),
        tostring(definition.open_time), tostring(definition.ready_timeout), tostring(seam or "auto"),
        tostring(definition.acceleration), tostring(definition.deceleration),
        tostring(definition.start_delay), tostring(definition.endpoint_wait),
        tostring(#(definition.handoff_points or {})),
    }
    for _, point in ipairs(definition.handoff_points or {}) do
        parts[#parts + 1] = tostring(type(point) == "table" and point.y or point)
    end
    return table.concat(parts, "|")
end

function M.validate_definition(definition, options)
    options = options or {}
    if type(definition) ~= "table" then return false, "definition must be a table" end
    local id = normalize_id(definition.id or definition.elevator_id)
    if not id then return false, "definition requires elevator_id" end

    local bottom = definition.bottom
    local top = definition.top
    if not bottom or not top then return false, "definition requires exactly one bottom and one top node" end
    local bottom_room = normalize_room_id(bottom.room_id or definition.bottom_room_id)
    local top_room = normalize_room_id(top.room_id or definition.top_room_id)
    if not bottom_room or not top_room then return false, "both nodes require room_id" end
    if bottom_room == top_room then return false, "elevator endpoints must be in different rooms" end

    local state_config = {
        bottom = bottom.position or bottom,
        top = top.position or top,
        home_stop = definition.home_stop,
        speed = definition.speed,
        close_time = definition.close_time,
        open_time = definition.open_time,
        ready_timeout = definition.ready_timeout,
        seam_y = definition.seam_y_authored == true and definition.seam_y or nil,
        acceleration = definition.acceleration,
        deceleration = definition.deceleration,
        start_delay = definition.start_delay,
        endpoint_wait = definition.endpoint_wait,
        handoff_points = definition.handoff_points and #definition.handoff_points > 0
            and definition.handoff_points or nil,
    }
    local valid, err = State.validate(state_config)
    if not valid then return false, err end

    if options.require_adjacency then
        local manager = options.room_manager or get_room_manager()
        if not manager or not manager.get_room_neighbors then
            return false, "cannot validate adjacency before the room layout is loaded"
        end
        local route = definition.route_room_ids
        if type(route) ~= "table" or #route < 2 then
            route = { bottom_room, top_room }
        end
        for index = 1, #route - 1 do
            local source_room = normalize_room_id(route[index])
            local target_room = normalize_room_id(route[index + 1])
            if not source_room or not target_room or source_room == target_room then
                return false, "elevator route contains an invalid room transition"
            end
            local ok, neighbors = pcall(manager.get_room_neighbors, source_room)
            if not ok then return false, "failed to query room adjacency" end
            local adjacent = false
            for _, neighbor in ipairs(neighbors or {}) do
                if normalize_room_id(neighbor.id) == target_room then
                    adjacent = true
                    break
                end
            end
            if not adjacent then
                return false, string.format(
                    "elevator route rooms '%s' and '%s' must be adjacent",
                    source_room, target_room)
            end
        end
    end

    return true
end

local attach_cabin_internal

local function build_machine(record)
    local definition = definition_view(record)
    if not definition.bottom or not definition.top then
        record.definition_error = "waiting_for_two_nodes"
        return false, record.definition_error
    end

    local valid, err = M.validate_definition(definition)
    if not valid then
        record.definition_error = err
        return false, err
    end

    local fingerprint = config_fingerprint(definition)
    if record.machine and record.machine_fingerprint == fingerprint then
        record.definition_error = nil
        return true
    end
    if record.machine and record.machine:is_busy() then
        record.definition_error = "cannot rebuild an elevator while it is moving"
        return false, record.definition_error
    end

    local initial_stop = definition.home_stop
    local persistence = persistence_adapter()
    if definition.restore_to_last_landing
        and type(persistence.get_landing) == "function" then
        local ok_restore, restored = pcall(persistence.get_landing, record.id, definition)
        if ok_restore and normalize_stop(restored) then initial_stop = normalize_stop(restored) end
    end

    local machine, state_err = State.new({
        bottom = definition.bottom.position,
        top = definition.top.position,
        home_stop = definition.home_stop,
        initial_stop = initial_stop,
        speed = definition.speed,
        acceleration = definition.acceleration,
        deceleration = definition.deceleration,
        start_delay = definition.start_delay,
        close_time = definition.close_time,
        open_time = definition.open_time,
        endpoint_wait = definition.endpoint_wait,
        ready_timeout = definition.ready_timeout,
        seam_y = definition.seam_y_authored and definition.seam_y or nil,
        handoff_points = definition.handoff_points and #definition.handoff_points > 0
            and definition.handoff_points or nil,
    })
    if not machine then
        record.definition_error = state_err
        return false, state_err
    end

    record.machine = machine
    record.machine_fingerprint = fingerprint
    record.definition_error = nil
    record.enabled = definition.enabled ~= false
    return true
end

local function factory_properties(record)
    local definition = definition_view(record)
    local bottom = definition.bottom.position
    local top = definition.top.position
    return {
        elevator_id = record.id,
        trigger_id = definition.trigger_id or record.id,
        cabin_resource_key = definition.cabin_resource_key or record.id,
        home_stop = definition.home_stop,
        bottom_room_id = definition.bottom_room_id,
        top_room_id = definition.top_room_id,
        bottom_x = bottom.x,
        bottom_y = bottom.y,
        bottom_z = bottom.z,
        top_x = top.x,
        top_y = top.y,
        top_z = top.z,
        seam_y = definition.seam_y_authored and (finite_number(definition.seam_y) or 0) or 0,
        seam_y_authored = definition.seam_y_authored,
        speed = definition.speed,
        acceleration = definition.acceleration,
        deceleration = definition.deceleration,
        endpoint_wait = definition.endpoint_wait,
        start_delay = definition.start_delay,
        close_time = definition.close_time,
        open_time = definition.open_time,
        ready_timeout = definition.ready_timeout,
        camera_priority = definition.camera_priority,
        width = definition.width,
        height = definition.height,
        carry_player = definition.carry_player,
        carry_enemies = definition.carry_enemies,
        carry_pushables = definition.carry_pushables,
        require_rider = definition.require_rider,
        activation_mode = definition.activation_mode,
        require_interact = definition.require_interact,
        camera_follow = definition.camera_follow,
        camera_lock_x = definition.camera_lock_x,
        camera_look_ahead = definition.camera_look_ahead,
        camera_blend_time = definition.camera_blend_time,
        enabled = definition.enabled,
        spawn_generation = world_generation,
    }
end

function M.default_factory_url(resource_key)
    local component_id = Contract.factory_component_id(resource_key)
    if not component_id or not msg or type(msg.url) ~= "function" then return nil end
    local ok, parsed = pcall(msg.url, "main:/room_factories#" .. component_id)
    if not ok or not parsed then return nil end
    local constants = get_constants()
    local room_manager_url = constants and constants.URL and constants.URL.ROOM_MANAGER
    if room_manager_url then
        local ok_room, room_url = pcall(msg.url, room_manager_url)
        if ok_room and room_url and room_url.socket then
            local ok_active, active = pcall(msg.url, room_url.socket, parsed.path, parsed.fragment)
            if ok_active then return active end
        end
    end
    return parsed
end

local function find_spawned_cabin(created)
    if type(created) ~= "table" then return nil end
    local root = created[safe_hash("/cabin")] or created[safe_hash("cabin")]
    if root then return root end
    -- Hashes cannot always be reversed in release builds. The generated
    -- collection contract still has one cabin root and one collision child;
    -- prefer a URL ending in /cabin, then deliberately refuse to guess.
    for _, url in pairs(created) do
        local text = tostring(url or "")
        if text:match("/cabin[#%]]") or text:match("/cabin$") then return url end
    end
    return nil
end

function M.default_spawn_cabin(definition, properties, position)
    if not collectionfactory or type(collectionfactory.create) ~= "function" then
        return nil, "collectionfactory unavailable"
    end
    local factory_url = M.default_factory_url(definition and definition.cabin_resource_key)
    if not factory_url then return nil, "elevator factory URL unavailable" end
    -- Collection-factory overrides are keyed by the collection instance id;
    -- the generated contract deliberately names the persistent root `cabin`.
    local root_properties = {
        [safe_hash("/cabin")] = properties or {},
    }
    local ok, created = pcall(collectionfactory.create, factory_url,
        to_engine_position(position or { x = 0, y = 0, z = 0 }), nil, root_properties, 1)
    if not ok then return nil, tostring(created) end
    if created == nil then return nil, "collectionfactory returned no instances" end
    local root = find_spawned_cabin(created)
    if not root then return nil, "generated elevator collection has no root id 'cabin'" end
    return root, created
end

local function ensure_cabin_spawn(record)
    if record.cabin_url or record.spawn_pending or not record.machine then return true end
    local definition = definition_view(record)
    record.spawn_pending = true
    record.spawn_generation = world_generation
    local properties = factory_properties(record)
    local ok, result, spawn_error
    if type(adapters.spawn_cabin) == "function" then
        ok, result = pcall(adapters.spawn_cabin, definition, properties)
    else
        ok = true
        result, spawn_error = M.default_spawn_cabin(definition, properties,
            record.machine:get_position())
        -- Standalone tests intentionally provide no collectionfactory result
        -- and attach a fake cabin explicitly; keep the definition usable.
        if result == nil and (spawn_error == "collectionfactory returned no instances"
            or spawn_error == "collectionfactory unavailable") then
            record.spawn_pending = false
            return true
        end
    end
    if not ok or result == false or result == nil then
        record.spawn_pending = false
        record.definition_error = "persistent cabin spawn failed: "
            .. tostring(spawn_error or result)
        return false, record.definition_error
    end

    -- factory.create may return the URL immediately while init() attaches the
    -- script synchronously.  Preserve either route without manufacturing a
    -- second attachment token.
    if result ~= nil and result ~= true and not record.cabin_url then
        record.cabin_owner_url = object_url(result)
        if msg and type(msg.url) == "function" then
            local ok_root, root = pcall(msg.url, record.cabin_owner_url)
            if ok_root and root then
                local ok_script, script_url = pcall(msg.url, root.socket, root.path, safe_hash("script"))
                record.cabin_url = ok_script and script_url or result
            else
                record.cabin_url = result
            end
        else
            record.cabin_url = result
        end
    end
    record.spawn_pending = false
    return true
end

local function ensure_ready(record)
    local ok, err = build_machine(record)
    if not ok then return false, err end
    return ensure_cabin_spawn(record)
end

function M.configure(new_adapters)
    new_adapters = new_adapters or {}
    for key, value in pairs(new_adapters) do
        adapters[key] = value
    end
    for _, record in pairs(records) do
        ensure_cabin_spawn(record)
    end
end

function M.get_world_generation()
    return world_generation
end

function M.register_controller(definition)
    definition = definition or {}
    local raw_id = definition.elevator_id or definition.id
    local key = Identity.elevator_key(raw_id)
    if not key then return nil, "controller requires elevator_id" end

    local record = get_or_create(key, Identity.authored_id(raw_id))
    if not record.controller_canonical then
        merge_controller(record.controller, definition)
    end
    record.enabled = record.controller.enabled ~= false

    registration_serial = registration_serial + 1
    local registration = string.format("controller:%d:%s:%d", world_generation, record.id, registration_serial)
    record.controller_live = {
        url = definition.url,
        registration = registration,
    }

    local _, err = ensure_ready(record)
    return registration, err
end

function M.unregister_controller(id, url, registration)
    local record = records[Identity.elevator_key(id)]
    if not record or not record.controller_live then return false end
    local live = record.controller_live
    if registration and registration ~= live.registration then return false end
    if url and live.url and tostring(url) ~= tostring(live.url) then return false end
    record.controller_live = nil
    -- Authored metadata remains cached until reset_world().
    return true
end

function M.register_node(definition)
    definition = definition or {}
    local raw_id = definition.elevator_id or definition.id
    local key = Identity.elevator_key(raw_id)
    if not key then return nil, "node requires elevator_id" end

    local record = get_or_create(key, Identity.authored_id(raw_id))
    local canonical = definition.node_id
        and record.route_nodes[Identity.node_key(definition.node_id)] or nil
    if canonical and canonical.canonical then
        registration_serial = registration_serial + 1
        canonical.registration = string.format("node:%d:%s:%s:%d",
            world_generation, record.id, tostring(canonical.stop or canonical.kind), registration_serial)
        canonical.url = definition.url
        return canonical.registration
    end

    local node, err = normalize_node(definition)
    if not node then return nil, err end

    registration_serial = registration_serial + 1
    node.registration = string.format("node:%d:%s:%s:%d",
        world_generation, record.id, tostring(node.stop or node.kind), registration_serial)
    record.route_nodes[route_node_key(node)] = node
    rebuild_route(record)

    local _, ready_err = ensure_ready(record)
    return node.registration, ready_err
end

function M.unregister_node(id, stop, url, registration)
    local record = records[Identity.elevator_key(id)]
    local normalized_stop = normalize_stop(stop)
    local node = record and normalized_stop and record.nodes[normalized_stop] or nil
    if not node and record then
        for _, candidate in pairs(record.route_nodes or {}) do
            if (not registration or candidate.registration == registration)
                and (not url or not candidate.url or tostring(candidate.url) == tostring(url)) then
                node = candidate
                break
            end
        end
    end
    if not node then return false end
    if registration and registration ~= node.registration then return false end
    if url and node.url and tostring(url) ~= tostring(node.url) then return false end
    -- Retain room/position metadata, but clear the ephemeral URL so messages
    -- are never delivered to a replacement GO by mistake.
    node.url = nil
    node.registration = nil
    return true
end

function M.register_definition(definition)
    definition = definition or {}
    local raw_id = definition.elevator_id or definition.id
    local key = Identity.elevator_key(raw_id)
    if not key then return false, "definition requires elevator_id" end
    local authored_id = Identity.authored_id(raw_id) or normalize_id(raw_id)
    local record = get_or_create(key, authored_id)

    if type(definition.settings) == "table" then
        merge_controller(record.controller, definition.settings)
    end
    merge_controller(record.controller, definition)
    record.controller_canonical = true
    record.enabled = record.controller.enabled ~= false

    local bottom_def = definition.bottom
    local top_def = definition.top
    if bottom_def then
        local node, err = normalize_node({
            elevator_id = record.id,
            node_id = bottom_def.node_id,
            stop = State.STOP_BOTTOM,
            room_id = bottom_def.room_id or definition.bottom_room_id,
            door_id = bottom_def.door_id,
            position = bottom_def.position or bottom_def,
            local_position = bottom_def.local_position,
            url = bottom_def.url,
        })
        if not node then return false, err end
        node.stop = State.STOP_BOTTOM
        record.route_nodes[route_node_key(node)] = node
    end
    if top_def then
        local node, err = normalize_node({
            elevator_id = record.id,
            node_id = top_def.node_id,
            stop = State.STOP_TOP,
            room_id = top_def.room_id or definition.top_room_id,
            door_id = top_def.door_id,
            position = top_def.position or top_def,
            local_position = top_def.local_position,
            url = top_def.url,
        })
        if not node then return false, err end
        node.stop = State.STOP_TOP
        record.route_nodes[route_node_key(node)] = node
    end

    for _, route_definition in ipairs(definition.route_nodes or definition.nodes or {}) do
        local node, err = normalize_node({
            elevator_id = record.id,
            node_id = route_definition.node_id,
            node_kind = route_definition.node_kind or route_definition.kind,
            stop = route_definition.stop,
            room_id = route_definition.room_id,
            door_id = route_definition.door_id,
            position = route_definition.position or route_definition,
            local_position = route_definition.local_position,
            url = route_definition.url,
            order = route_definition.order,
            canonical = route_definition.canonical,
        })
        if not node then return false, err end
        record.route_nodes[route_node_key(node)] = node
    end
    rebuild_route(record)

    if type(definition.route_room_ids) == "table" and #definition.route_room_ids >= 2 then
        record.route_room_ids = {}
        for _, room_id in ipairs(definition.route_room_ids) do
            local normalized = normalize_room_id(room_id)
            if normalized and record.route_room_ids[#record.route_room_ids] ~= normalized then
                record.route_room_ids[#record.route_room_ids + 1] = normalized
            end
        end
    end
    if type(definition.handoff_points) == "table" and #definition.handoff_points > 0 then
        record.handoff_points = definition.handoff_points
    end

    return ensure_ready(record)
end

-- Register the output of mvtk.elevators.layout_resolver.  Resolved node
-- coordinates describe the cabin floor/shaft center, while the persistent GO
-- origin is the authored controller rectangle's bottom-left corner.
function M.register_resolved(definition)
    if type(definition) ~= "table" then return false, "resolved definition must be a table" end
    if definition.valid == false then return false, "resolved definition is invalid" end
    if type(definition.runtime_definition) == "table" then
        local runtime = definition.runtime_definition
        runtime.settings = runtime.settings or definition.settings
        runtime.trigger_id = runtime.trigger_id
            or (definition.settings and definition.settings.trigger_id)
        for _, node in ipairs(runtime.route_nodes or {}) do node.canonical = true end
        -- The resolver derives these points from the actual reciprocal door
        -- seam, including the cabin floor offset.  Do not replace them with
        -- route-node midpoints; asymmetric door markers depend on this value.
        if type(runtime.handoff_points) ~= "table" or #runtime.handoff_points == 0 then
            runtime.handoff_points = definition.state_config
                and definition.state_config.handoff_points or runtime.handoff_points
        end
        return M.register_definition(runtime)
    end
    local settings = definition.settings or {}
    local controller = definition.controller or {}
    local landings = definition.landings or {}
    local bottom_landing = landings[1]
    local top_landing = landings[#landings]
    if not bottom_landing or not top_landing or bottom_landing == top_landing then
        return false, "resolved elevator requires two landing endpoints"
    end

    local width = finite_number(controller.width) or 128
    local height = finite_number(controller.height) or 32
    local floor_offset = finite_number(settings.floor_offset) or height
    local shaft_x = finite_number(definition.shaft_x)
        or finite_number(controller.world_center_x)
        or ((finite_number(controller.world_x) or 0) + width * 0.5)
    local root_x = shaft_x - width * 0.5
    local visual_z = finite_number(settings.visual_z) or 0

    local route_nodes = {}
    for _, node in ipairs(definition.nodes or {}) do
        route_nodes[#route_nodes + 1] = {
            elevator_id = definition.id,
            node_id = node.node_id,
            node_kind = node.kind or node.node_kind,
            stop = node.stop,
            room_id = node.room_id,
            door_id = node.door_id,
            order = node.order,
            canonical = true,
            position = {
                x = root_x,
                y = (finite_number(node.world_y) or 0) - floor_offset,
                z = visual_z,
            },
        }
    end

    local home_stop = State.STOP_BOTTOM
    if definition.start_node and definition.start_node.node_id == top_landing.node_id then
        home_stop = State.STOP_TOP
    end

    local runtime_definition = {
        id = definition.id,
        elevator_id = definition.id,
        cabin_resource_key = definition.resource_key or definition.id,
        trigger_id = settings.trigger_id,
        settings = settings,
        home_stop = home_stop,
        width = width,
        height = height,
        bottom = {
            node_id = bottom_landing.node_id,
            room_id = bottom_landing.room_id,
            door_id = bottom_landing.door_id,
            position = { x = root_x, y = bottom_landing.world_y - floor_offset, z = visual_z },
        },
        top = {
            node_id = top_landing.node_id,
            room_id = top_landing.room_id,
            door_id = top_landing.door_id,
            position = { x = root_x, y = top_landing.world_y - floor_offset, z = visual_z },
        },
        route_nodes = route_nodes,
        route_room_ids = definition.room_ids,
        handoff_points = definition.state_config
            and definition.state_config.handoff_points or definition.handoff_points,
    }
    return M.register_definition(runtime_definition)
end

-- Load the generated authoring index after RoomManager.load_layout(), resolve
-- room-local coordinates against rebuilt room positions, then materialize all
-- persistent definitions before any destination marker has streamed in.
function M.load_generated_index(index, options)
    options = options or {}
    if index == nil then
        local module_name = options.module_name or "developer.config.elevators_generated"
        local ok, generated = pcall(require, module_name)
        if not ok then return false, "generated_elevator_index_unavailable:" .. tostring(generated) end
        index = generated
    end
    if type(index) ~= "table" then return false, "generated elevator index must return a table" end
    local manifest = index.manifest or index

    local room_provider = options.room_provider or get_room_manager()
    if not room_provider then return false, "room manager unavailable during elevator layout resolution" end
    local resolved, diagnostics = LayoutResolver.resolve(manifest, room_provider, options.resolve_options)
    if not resolved or resolved.valid == false then
        return false, {
            code = "elevator_layout_invalid",
            diagnostics = diagnostics or (resolved and resolved.diagnostics) or {},
            resolved = resolved,
        }
    end

    if options.reset ~= false then
        M.reset_world({ reason = "load_generated_elevators" })
    end
    local errors = {}
    for _, id in ipairs(resolved.ordered_ids or {}) do
        local ok, err = M.register_resolved(resolved.elevators[id])
        if not ok then errors[#errors + 1] = { elevator_id = id, error = err } end
    end
    return #errors == 0, {
        resolved = resolved,
        diagnostics = diagnostics or {},
        errors = errors,
        world_generation = world_generation,
    }
end

M.initialize_from_generated = M.load_generated_index

attach_cabin_internal = function(definition)
    definition = definition or {}
    local raw_id = definition.elevator_id or definition.id
    local key = Identity.elevator_key(raw_id)
    if not key then return nil, "cabin requires elevator_id" end
    local spawn_generation = math.floor(finite_number(definition.spawn_generation) or world_generation)
    if spawn_generation ~= world_generation then
        return nil, "stale_spawn_generation"
    end

    local record = get_or_create(key, Identity.authored_id(raw_id))
    if not record.controller_canonical then
        merge_controller(record.controller, definition)
    end
    if not record.machine and definition.bottom and definition.top then
        local ok, err = M.register_definition(definition)
        if not ok then return nil, err end
    end
    local ok, err = ensure_ready(record)
    if not ok then return nil, err end

    attachment_serial = attachment_serial + 1
    local token = string.format("cabin:%d:%s:%d", world_generation, record.id, attachment_serial)
    local new_url = definition.url
    local new_owner = definition.owner_url or object_url(new_url)

    if record.attachment_token and record.cabin_url and tostring(record.cabin_url) ~= tostring(new_url) then
        safe_post(record.cabin_url, "elevator_replaced", {
            elevator_id = record.id,
            world_generation = world_generation,
        })
    end

    record.cabin_url = new_url or record.cabin_url
    record.cabin_owner_url = new_owner or record.cabin_owner_url
    record.attachment_token = token
    record.spawn_pending = false
    record.spawn_generation = world_generation

    return token, record.machine:snapshot()
end

function M.attach_cabin(definition)
    return attach_cabin_internal(definition)
end

M.materialize = M.attach_cabin

function M.detach_cabin(id, token)
    local record = records[Identity.elevator_key(id)]
    if not record or not record.attachment_token then return false end
    if token ~= record.attachment_token then return false end
    record.cabin_url = nil
    record.cabin_owner_url = nil
    record.attachment_token = nil
    record.spawn_pending = false
    return true
end

local function source_and_target(record)
    local from = record.machine and record.machine.from_stop
    local target = record.machine and record.machine.target_stop
    return record.nodes[from], record.nodes[target]
end

local function begin_room_handoff(record)
    local source_node, target_node = source_and_target(record)
    if not source_node or not target_node then return false, "missing_route_node" end
    if not record.cabin_owner_url then return false, "cabin_not_attached" end

    local route = record.active_route or { source_node.room_id, target_node.room_id }
    local options = {
        route = route,
        -- The state machine can consume several seams in one large frame.
        -- Enable the pinned route before departure so every seam has collision.
        visible_ahead = #route,
        generation = record.machine.generation,
        elevator_id = record.id,
        background = record.empty_trip == true,
    }

    local room = adapters.room
    if room and type(room.begin_handoff) == "function" then
        local ok, token = pcall(room.begin_handoff, record.cabin_owner_url, options, record)
        if not ok or token == false or token == nil then
            return false, tostring(token or "room adapter rejected handoff")
        end
        record.room_token = token
        return true
    end

    local manager = get_room_manager()
    if manager and type(manager.begin_handoff) == "function" then
        local ok, token = pcall(manager.begin_handoff, record.cabin_owner_url, options)
        if not ok or token == false or token == nil then
            return false, tostring(token or "room manager rejected handoff")
        end
        record.room_token = token
        return true
    end

    -- Compatibility fallback for projects that have not yet adopted handoff
    -- leases.  Directly adjacent rooms are loaded, but robust integrations
    -- should provide RoomManager.begin_handoff/finish_handoff.
    if manager and type(manager.load_room) == "function" and type(manager.get_room_data) == "function" then
        local room_data = manager.get_room_data(target_node.room_id)
        if not room_data then return false, "unknown_target_room" end
        local x, y = require("mvtk.map.streaming.room_geometry").compute_spawn_xy(room_data)
        local position = to_engine_position({
            x = x,
            y = y,
            z = 0,
        })
        local ok, loaded = pcall(manager.load_room, target_node.room_id, position)
        if not ok or loaded == false then return false, "target_room_load_failed" end
        record.room_token = { legacy = true, target_room_id = target_node.room_id }
        return true
    end

    return false, "room_handoff_api_unavailable"
end

local function room_readiness(record)
    local _, target_node = source_and_target(record)
    if not target_node then return false, true, "missing_target_node" end
    local route = record.active_route or { target_node.room_id }

    local room = adapters.room
    if room and type(room.is_ready) == "function" then
        for index = 2, #route do
            local ok, ready, failed, reason = pcall(room.is_ready,
                record.room_token, route[index], record)
            if not ok then return false, true, tostring(ready) end
            if failed == true then return false, true, reason end
            if ready ~= true then return false, false, reason end
        end
        return true, false, nil
    end

    local manager = get_room_manager()
    if manager and type(manager.is_handoff_ready) == "function" then
        for index = 2, #route do
            local ok, ready, failed, reason = pcall(manager.is_handoff_ready,
                record.room_token, route[index])
            if not ok then return false, true, tostring(ready) end
            if failed == true then return false, true, reason end
            if ready ~= true then return false, false, reason end
        end
        return true, false, nil
    end
    if manager and type(manager.is_room_ready) == "function" then
        for index = 2, #route do
            local ok, ready = pcall(manager.is_room_ready, route[index])
            if not ok then return false, true, tostring(ready) end
            if ready ~= true then return false, false, nil end
        end
        return true, false, nil
    end
    return false, true, "room_readiness_api_unavailable"
end

local function advance_room_handoff(record)
    local route = record.active_route
    local next_index = (record.active_route_index or 1) + 1
    local destination_room = route and route[next_index] or nil
    if not destination_room then return false, "missing_next_route_room" end
    local room = adapters.room
    if room and type(room.advance_handoff) == "function" then
        local ok, result, err = pcall(room.advance_handoff,
            record.room_token, destination_room, record)
        if ok and result ~= false then record.active_route_index = next_index end
        return ok and result ~= false, ok and err or tostring(result)
    end

    local manager = get_room_manager()
    if manager and type(manager.advance_handoff) == "function" then
        local ok, result, err = pcall(manager.advance_handoff, record.room_token, destination_room)
        if ok and result ~= false then record.active_route_index = next_index end
        return ok and result ~= false, ok and err or tostring(result)
    end
    if manager and type(manager.set_current_room) == "function" then
        local ok, result = pcall(manager.set_current_room, destination_room)
        if ok and result ~= false then record.active_route_index = next_index end
        return ok and result ~= false, ok and nil or tostring(result)
    end
    return false, "room_advance_api_unavailable"
end

local function finish_room_handoff(record)
    if not record.room_token then return end
    local token = record.room_token
    record.room_token = nil

    local room = adapters.room
    if room and type(room.finish_handoff) == "function" then
        pcall(room.finish_handoff, token, record)
        return
    end
    local manager = get_room_manager()
    if manager and type(manager.finish_handoff) == "function" then
        pcall(manager.finish_handoff, token)
    end
end

local function camera_url(record)
    if record.controller.camera_url then return record.controller.camera_url end
    local constants = get_constants()
    return constants and constants.URL and constants.URL.CAMERA or nil
end

local function live_player_url(value)
    if value == nil then return nil end
    if go and type(go.exists) == "function" then
        local ok, exists = pcall(go.exists, object_url(value))
        if ok then return exists and value or nil end
    end
    return value
end

local function camera_player_url(definition)
    -- The persistent cabin can initialize before the player factory. Prefer
    -- its explicit URL once live, then consult the mutable global URL that the
    -- player spawner publishes later in the same world.
    local explicit = live_player_url(definition and definition.player_url)
    if explicit then return explicit end
    local constants = get_constants()
    return live_player_url(constants and constants.URL and constants.URL.PLAYER)
end

local function camera_look_ahead_y(definition, source_node, target_node)
    local amount = finite_number(definition and definition.camera_look_ahead) or 0
    local source_y = source_node and source_node.position
        and finite_number(source_node.position.y) or nil
    local target_y = target_node and target_node.position
        and finite_number(target_node.position.y) or nil
    if not source_y or not target_y or source_y == target_y then return 0 end
    return amount * (target_y > source_y and 1 or -1)
end

local function camera_payload(record, event, extras)
    local definition = definition_view(record)
    local snapshot = record.machine:snapshot()
    local source_node, target_node = source_and_target(record)
    local token = string.format("%s:%d", record.id, record.active_generation or snapshot.generation)
    local look_ahead_y = camera_look_ahead_y(definition, source_node, target_node)
    local focus_position = copy_position(event and event.position or snapshot.position)
    focus_position.y = focus_position.y + look_ahead_y
    local payload = {
        owner = record.cabin_owner_url or record.id,
        owner_id = record.id,
        elevator_id = record.id,
        generation = record.active_generation or snapshot.generation,
        token = token,
        priority = definition.camera_priority,
        mode = "elevator",
        player_url = camera_player_url(definition),
        position = to_engine_position(focus_position),
        anchor = to_engine_position(focus_position),
        shaft_x = definition.bottom.position.x + (definition.width * 0.5),
        lock_x = definition.camera_lock_x,
        look_ahead = definition.camera_look_ahead,
        follow_offset_y = look_ahead_y,
        blend_in = definition.camera_blend_time,
        -- Cabin travel limits are not viewport bounds: the rider stands above
        -- the cabin, and the view extends into the pinned landing rooms.
        -- Clamping to the cabin route parks the camera before arrival, lets
        -- the rider leave the screen, then snaps back when the lease ends.
        corridor = false,
        source_room_id = source_node and source_node.room_id or definition.bottom_room_id,
        target_room_id = target_node and target_node.room_id or definition.top_room_id,
    }
    for key, value in pairs(extras or {}) do payload[key] = value end
    return payload
end

local function acquire_camera(record, event)
    if record.camera_token then return end
    if record.empty_trip then return end
    if definition_view(record).camera_follow == false then return end
    local payload = camera_payload(record, event)
    local camera = adapters.camera
    if camera and type(camera.acquire) == "function" then
        local ok, token = pcall(camera.acquire, record, payload)
        if ok and token ~= false then record.camera_token = token or payload.token end
        return
    end
    local url = camera_url(record)
    if url and safe_post(url, "camera_focus_acquire", payload) then
        record.camera_token = payload.token
    end
end

local function update_camera(record, event, extras)
    if not record.camera_token then return end
    local payload = camera_payload(record, event, extras)
    payload.token = record.camera_token
    local camera = adapters.camera
    if camera and type(camera.update) == "function" then
        pcall(camera.update, record.camera_token, payload, record)
        return
    end
    safe_post(camera_url(record), "camera_focus_update", payload)
end

local function release_camera(record, reason, event)
    if not record.camera_token then return end
    local token = record.camera_token
    record.camera_token = nil
    local payload = camera_payload(record, event, {
        token = token,
        reason = reason,
        room_id = record.machine and record.nodes[record.machine.current_stop]
            and record.nodes[record.machine.current_stop].room_id or nil,
    })
    local camera = adapters.camera
    if camera and type(camera.release) == "function" then
        pcall(camera.release, token, payload, record)
        return
    end
    safe_post(camera_url(record), "camera_focus_release", payload)
end

local function notify_node(node, message_id, record, event)
    if not node or not node.url then return end
    safe_post(node.url, message_id, {
        elevator_id = record.id,
        generation = event.generation,
        stop = node.stop,
        position = to_engine_position(event.position),
        reason = event.reason,
    })
end

local function cleanup_trip(record, reason, event)
    release_camera(record, reason, event)
    finish_room_handoff(record)
    record.active_generation = nil
    record.active_route = nil
    record.active_route_index = nil
    record.empty_trip = nil
end

local function dispatch_event(record, event)
    if event.type == "doors_closing" then
        acquire_camera(record, event)
        notify_node(record.nodes[event.stop], "elevator_doors_closing", record, event)
    elseif event.type == "departed" then
        notify_node(record.nodes[event.from_stop], "elevator_departed", record, event)
        notify_node(record.nodes[event.target_stop], "elevator_incoming", record, event)
    elseif event.type == "moved" then
        update_camera(record, event, {
            dx = event.dx,
            dy = event.dy,
            dz = event.dz,
        })
    elseif event.type == "room_handoff" then
        local room_id = record.active_route
            and record.active_route[record.active_route_index or 1] or nil
        update_camera(record, event, {
            handoff = true,
            room_id = room_id,
            target_room_id = room_id,
        })
    elseif event.type == "arrived" then
        notify_node(record.nodes[event.stop], "elevator_arrived", record, event)
    elseif event.type == "doors_opening" then
        notify_node(record.nodes[event.stop], "elevator_doors_opening", record, event)
    elseif event.type == "trip_completed" then
        notify_node(record.nodes[event.stop], "elevator_trip_completed", record, event)
        local definition = definition_view(record)
        local persistence = persistence_adapter()
        if definition.persist_landing and type(persistence.set_landing) == "function" then
            pcall(persistence.set_landing, record.id, event.stop, definition)
        end
        cleanup_trip(record, "completed", event)
    elseif event.type == "trip_failed" or event.type == "reset" then
        record.queued_stop = nil
        record.queued_options = nil
        cleanup_trip(record, event.reason or event.type, event)
    end

    if record.controller_live and record.controller_live.url then
        safe_post(record.controller_live.url, "elevator_event", event)
    end
    if type(adapters.on_event) == "function" then
        pcall(adapters.on_event, record.id, event, record.machine:snapshot())
    end
end

local function dispatch_events(record, events)
    for i = 1, #(events or {}) do
        dispatch_event(record, events[i])
    end
end

-- Checkpoint loading can occur after RoomManager has resolved and materialized
-- the persistent cabins. Reconcile already-built idle machines when the
-- default provider applies a slot so initialization order cannot discard the
-- saved landing. A different configured adapter remains fully authoritative.
function M.refresh_persisted_landings(reason)
    local results = {}
    if type(adapters.persistence) == "table" then return results end
    for _, record in pairs(records) do
        local definition = definition_view(record)
        if definition.restore_to_last_landing and record.machine then
            local restored = normalize_stop(DefaultPersistence.get_landing(record.id))
                or definition.home_stop
            local snapshot = record.machine:snapshot()
            if snapshot.state ~= State.STATE_IDLE or snapshot.current_stop ~= restored then
                local events = record.machine:reset(restored,
                    reason or "persisted_landing_loaded")
                record.queued_stop = nil
                record.queued_options = nil
                dispatch_events(record, events)
                results[record.id] = record.machine:snapshot()
            end
        end
    end
    return results
end

function M.request(id, target_stop, options)
    options = options or {}
    local record = records[Identity.elevator_key(id)]
    if not record then return false, "unknown_elevator" end
    local ready, ready_err = ensure_ready(record)
    if not ready then return false, ready_err end
    if record.enabled == false and options.force ~= true then return false, "disabled" end
    if not record.attachment_token and not record.cabin_owner_url then return false, "cabin_not_attached" end

    local target = normalize_stop(target_stop)
    if not target then
        target = State.other_stop(record.machine.current_stop)
    end
    if not target then return false, "invalid_stop" end

    if record.machine:is_busy() then
        if target == record.machine.target_stop or target == record.queued_stop then
            return true, "coalesced", record.machine.generation
        end
        record.queued_stop = target
        record.queued_options = { empty = options.empty == true }
        return true, "queued", record.machine.generation
    end

    local accepted, reason, events = record.machine:request(target)
    if not accepted then return false, reason, record.machine.generation end
    record.empty_trip = options.empty == true
    record.active_generation = record.machine.generation
    record.active_route = {}
    local authored_route = record.route_room_ids
    if not authored_route or #authored_route < 2 then
        authored_route = {
            record.nodes[State.STOP_BOTTOM].room_id,
            record.nodes[State.STOP_TOP].room_id,
        }
    end
    if record.machine.from_stop == State.STOP_BOTTOM then
        for i = 1, #authored_route do record.active_route[#record.active_route + 1] = authored_route[i] end
    else
        for i = #authored_route, 1, -1 do record.active_route[#record.active_route + 1] = authored_route[i] end
    end
    record.active_route_index = 1

    if #record.active_route - 1 ~= #record.machine.trip_handoffs then
        local mismatch_events = record.machine:fail("route_handoff_count_mismatch")
        dispatch_events(record, mismatch_events)
        return false, "route_handoff_count_mismatch", record.machine.generation
    end
    dispatch_events(record, events)

    local room_ok, room_err = begin_room_handoff(record)
    if not room_ok then
        local failure_events = record.machine:fail(room_err or "room_handoff_failed")
        dispatch_events(record, failure_events)
        return false, room_err, record.machine.generation
    end

    return true, "accepted", record.machine.generation
end

function M.update(id, dt, runtime, attachment_token)
    local record = records[Identity.elevator_key(id)]
    if not record or not record.machine then return nil, "unknown_elevator" end
    if attachment_token and attachment_token ~= record.attachment_token then
        return nil, "stale_cabin_attachment"
    end

    runtime = runtime or {}
    local start_position = record.machine:get_position()
    local all_events = {}
    local remaining = math.max(0, finite_number(dt) or 0)
    local loops = 0
    -- One update may cross every seam when a frame is unusually long (for
    -- example after a debugger pause).  Size the guard from the pinned route
    -- instead of assuming a two-room shape so pass-through rooms cannot
    -- leave otherwise-consumable dt stranded.
    local loop_limit = math.max(8, #(record.active_route or {}) + 4)

    repeat
        loops = loops + 1
        local destination_ready, destination_failed, readiness_reason = false, false, nil
        if record.machine.state == State.STATE_WAITING_READY then
            destination_ready, destination_failed, readiness_reason = room_readiness(record)
        end
        local result = record.machine:update(remaining, {
            destination_ready = destination_ready,
            destination_failed = destination_failed,
            failure_reason = readiness_reason,
            blocked = runtime.blocked == true,
            block_reason = runtime.block_reason,
        })
        remaining = result.remaining_dt or 0
        for _, event in ipairs(result.events) do
            all_events[#all_events + 1] = event
            dispatch_event(record, event)
        end

        if record.machine.state == State.STATE_HANDOFF then
            local handoff_ok, handoff_err = advance_room_handoff(record)
            local _, _, handoff_events = record.machine:confirm_handoff(handoff_ok, handoff_err)
            for _, event in ipairs(handoff_events or {}) do
                all_events[#all_events + 1] = event
                dispatch_event(record, event)
            end
            if not handoff_ok then remaining = 0 end
        else
            remaining = 0
        end
    until remaining <= 0.000001 or loops >= loop_limit

    if record.machine.state == State.STATE_IDLE and record.queued_stop then
        local queued = record.queued_stop
        local queued_options = record.queued_options
        record.queued_stop = nil
        record.queued_options = nil
        M.request(record.id, queued, queued_options)
    end

    local finish_position = record.machine:get_position()
    return {
        elevator_id = record.id,
        position = to_engine_position(finish_position),
        delta = to_engine_position({
            x = finish_position.x - start_position.x,
            y = finish_position.y - start_position.y,
            z = finish_position.z - start_position.z,
        }),
        events = all_events,
        snapshot = record.machine:snapshot(),
        remaining_dt = remaining,
    }
end

function M.cancel(id, reason, options)
    local record = records[Identity.elevator_key(id)]
    if not record or not record.machine then return nil, "unknown_elevator" end
    record.queued_stop = nil
    record.queued_options = nil
    local before = record.machine:get_position()
    local events = record.machine:cancel(reason, options)
    dispatch_events(record, events)
    local after = record.machine:get_position()
    return {
        position = to_engine_position(after),
        delta = to_engine_position({ x = after.x - before.x, y = after.y - before.y, z = after.z - before.z }),
        events = events,
        snapshot = record.machine:snapshot(),
    }
end

function M.cancel_all(reason, options)
    local results = {}
    for key, record in pairs(records) do
        if record.machine then
            results[record.id] = M.cancel(key, reason or "cancel_all", options)
        end
    end
    return results
end

function M.on_player_death()
    return M.cancel_all("player_died", { reset_home = true })
end

function M.set_enabled(id, enabled)
    local record = records[Identity.elevator_key(id)]
    if not record then return false end
    record.enabled = enabled ~= false
    return true
end

local function message_matches(message_id, name)
    if message_id == safe_hash(name) then return true end
    return normalize_id(message_id) == name
end

local function requested_stop(message_id, message)
    message = message or {}
    local explicit = normalize_stop(message.stop or message.target_stop or message.floor or message.target)
    if explicit then return explicit end
    if message_matches(message_id, "elevator_call_bottom") then return State.STOP_BOTTOM end
    if message_matches(message_id, "elevator_call_top") then return State.STOP_TOP end
    local direction = tostring(message.direction or ""):lower()
    if direction == "up" then return State.STOP_TOP end
    if direction == "down" then return State.STOP_BOTTOM end
    return nil
end

-- TriggerBus receiver contract used by elevator_cabin.script.
-- activate/trigger/elevator_call: enable and call (explicit stop or the other stop)
-- deactivate: disable future calls; never strands a moving passenger
-- elevator_cancel: explicit cancellation (faults in-shaft unless reset_home)
-- reset/player death: generation-safe home reset
function M.handle_trigger(id, message_id, message, sender, options)
    local record = records[Identity.elevator_key(id)]
    if not record then return false, "unknown_elevator" end
    message = message or {}

    if message_matches(message_id, "activate")
        or message_matches(message_id, "trigger")
        or message_matches(message_id, "elevator_call")
        or message_matches(message_id, "elevator_call_bottom")
        or message_matches(message_id, "elevator_call_top") then
        record.enabled = true
        return M.request(record.id, requested_stop(message_id, message), {
            sender = sender, empty = options and options.empty == true,
        })
    elseif message_matches(message_id, "deactivate") then
        record.enabled = false
        if message.cancel == true then
            return M.cancel(record.id, "deactivated", { reset_home = message.reset_home == true })
        end
        return true, "disabled"
    elseif message_matches(message_id, "enable") then
        record.enabled = true
        return true, "enabled"
    elseif message_matches(message_id, "set_enabled") then
        record.enabled = message.enabled ~= false
        return true, record.enabled and "enabled" or "disabled"
    elseif message_matches(message_id, "elevator_cancel") then
        return M.cancel(record.id, message.reason or "cancelled", {
            reset_home = message.reset_home == true,
            stop = message.stop,
        })
    elseif message_matches(message_id, "reset")
        or message_matches(message_id, "mvtk_reset_motion")
        or message_matches(message_id, "mvtk_player_died")
        or message_matches(message_id, "player_died") then
        return M.cancel(record.id, message.reason or "reset", { reset_home = true })
    end

    return false, "unsupported_message"
end

-- Call switches show a request until arrival, then stay pressed while the
-- cabin is at their landing. Read live state without copying the definition.
function M.get_call_status(id, stop)
    local key = Identity.elevator_key(id)
    local record = records[key]
    if not record then
        for _, candidate in pairs(records) do
            if Identity.elevator_key(definition_view(candidate).trigger_id) == key then
                record = candidate
                break
            end
        end
    end
    local machine = record and record.machine
    if not machine then return nil end
    local state = machine.state
    local present = machine.current_stop == stop
    if state == State.STATE_MOVING or state == State.STATE_HANDOFF or state == State.STATE_FAULTED then
        present = false
    elseif state == State.STATE_OPENING then
        present = machine.target_stop == stop
    end
    return present, state ~= State.STATE_FAULTED and (machine.target_stop == stop or record.queued_stop == stop),
        state == State.STATE_FAULTED, machine.generation
end

function M.get(id)
    local record = records[Identity.elevator_key(id)]
    if not record then return nil end
    local view = definition_view(record)
    view.snapshot = record.machine and record.machine:snapshot() or nil
    view.definition_error = record.definition_error
    view.cabin_url = record.cabin_url
    view.cabin_owner_url = record.cabin_owner_url
    view.attachment_token = record.attachment_token
    view.spawn_pending = record.spawn_pending
    view.room_token = record.room_token
    view.camera_token = record.camera_token
    view.queued_stop = record.queued_stop
    return view
end

function M.get_all()
    local result = {}
    for key, record in pairs(records) do result[record.id] = M.get(key) end
    return result
end

-- Exposed for release-mode contract tests and integrations that need to
-- compare a generated authored string with a GO hash property.
M.canonical_key = Identity.elevator_key

function M.reset_world(options)
    options = options or {}
    for _, record in pairs(records) do
        cleanup_trip(record, options.reason or "world_reset", nil)
        if record.cabin_url then
            if type(adapters.destroy_cabin) == "function" then
                pcall(adapters.destroy_cabin, record.cabin_url, options.reason or "world_reset", record)
            else
                local target = record.cabin_owner_url or object_url(record.cabin_url)
                if go and type(go.delete) == "function" and target then
                    pcall(go.delete, target, true)
                else
                    safe_post(record.cabin_url, "elevator_world_reset", {
                        elevator_id = record.id,
                        world_generation = world_generation,
                    })
                end
            end
        end
    end
    records = {}
    world_generation = world_generation + 1
    RoomManager = nil
    Constants = nil
    if options.clear_adapters then adapters = {} end
    return world_generation
end

function M.begin_world(definitions, new_adapters)
    M.reset_world({ reason = "begin_world" })
    if new_adapters then M.configure(new_adapters) end
    local errors = {}
    for _, definition in ipairs(definitions or {}) do
        local ok, err = M.register_definition(definition)
        if not ok then
            errors[#errors + 1] = {
                elevator_id = normalize_id(definition and (definition.elevator_id or definition.id)),
                error = err,
            }
        end
    end
    return #errors == 0, errors
end

DefaultPersistence.subscribe("elevator_manager", function(reason)
    M.refresh_persisted_landings(reason == "defaults"
        and "persisted_landing_defaults" or "persisted_landing_loaded")
end)

return M
