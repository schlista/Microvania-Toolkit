-- mvtk/world/teleporter_manager.lua
-- Registry for paired teleporter endpoints and per-actor cooldowns.

local M = {}

local teleporters_by_id = {}
local teleporters_by_pair = {}
local teleporter_stacks_by_id = {}
local recent_by_actor = {}
local static_teleporters_by_id = {}
local static_teleporters_by_pair = {}
local static_index_ready = false
local Time = require "mvtk.core.time"
local Util = require "mvtk.core.util"
local CollisionBox = require "mvtk.tiled.collision_box"
local Flags = require "mvtk.core.flags"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })

local normalize_id = Util.normalize_hash_string_keep_unknown
local teleporter_mgr_log = Util.make_debug_log("[TELEPORT_MGR]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.teleporters)
end)

local TiledParser = nil
local TiledRoomRegistry = nil
local RoomManager = nil

local function get_tiled_parser()
    if TiledParser == nil then
        local ok, mod = pcall(require, "mvtk.tiled.tiled_parser")
        TiledParser = ok and mod or false
    end
    if TiledParser == false then return nil end
    return TiledParser
end

local function get_tiled_room_registry()
    if TiledRoomRegistry == nil then
        local ok, mod = pcall(require, "mvtk.tiled.tiled_room_registry")
        TiledRoomRegistry = ok and mod or false
    end
    if TiledRoomRegistry == false then return nil end
    return TiledRoomRegistry
end

local function get_room_manager()
    if RoomManager == nil then
        local ok, mod = pcall(require, "mvtk.map.streaming.room_manager")
        RoomManager = ok and mod or false
    end
    if RoomManager == false then return nil end
    return RoomManager
end

local function normalize_object_type(value)
    if value == nil then
        return nil
    end
    local s = tostring(value):lower()
    s = s:gsub("[%s%-]+", "_")
    s = s:gsub("[^%w_]", "")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    if s == "" then
        return nil
    end
    return s
end

local function url_key(url)
    if not url then return nil end
    local ok, u = pcall(msg.url, url)
    if not ok or not u then return nil end
    return tostring(u.socket) .. "|" .. tostring(u.path) .. "|" .. tostring(u.fragment)
end

local function fmt_pos(pos)
    if not pos then
        return "nil"
    end
    return string.format("(%.1f, %.1f, %.1f)", tonumber(pos.x) or 0, tonumber(pos.y) or 0, tonumber(pos.z) or 0)
end

local function describe_entry(entry)
    if not entry then
        return "nil"
    end
    return string.format("id=%s target=%s pair=%s room=%s loaded=%s enabled=%s url=%s pos=%s local=%s",
        tostring(entry.id), tostring(entry.target_id), tostring(entry.pair_id),
        tostring(entry.room_id), tostring(entry.loaded), tostring(entry.enabled),
        tostring(entry.url), fmt_pos(entry.position), fmt_pos(entry.local_position))
end

local function object_url(component_url)
    if not component_url then
        return nil
    end
    local ok, u = pcall(msg.url, component_url)
    if not ok or not u then
        return nil
    end
    return msg.url(u.socket, u.path, nil)
end

local function go_exists_safe(url)
    if not url then
        return false
    end
    local ok, exists = pcall(go.exists, url)
    return ok and exists == true
end

local function get_world_position_safe(url)
    if not url then
        return nil
    end
    local ok, pos = pcall(go.get_world_position, url)
    if ok then
        return pos
    end
    return nil
end

local function store_by_pair(entry)
    if not entry.pair_id then return end
    local bucket = teleporters_by_pair[entry.pair_id]
    if not bucket then
        bucket = {}
        teleporters_by_pair[entry.pair_id] = bucket
    end
    bucket[entry.id] = entry
end

local function remove_by_pair(entry)
    if not entry.pair_id then return end
    local bucket = teleporters_by_pair[entry.pair_id]
    if not bucket then return end
    bucket[entry.id] = nil
    if not next(bucket) then
        teleporters_by_pair[entry.pair_id] = nil
    end
end

local function url_equals(a, b)
    if not a or not b then
        return false
    end
    local ok_a, ua = pcall(msg.url, a)
    local ok_b, ub = pcall(msg.url, b)
    if not ok_a or not ok_b or not ua or not ub then
        return tostring(a) == tostring(b)
    end
    return tostring(ua.socket) == tostring(ub.socket)
        and tostring(ua.path) == tostring(ub.path)
        and tostring(ua.fragment) == tostring(ub.fragment)
end

local function push_live_entry(id, record)
    local stack = teleporter_stacks_by_id[id]
    if not stack then
        stack = {}
        teleporter_stacks_by_id[id] = stack
    end

    for i = #stack, 1, -1 do
        if url_equals(stack[i].url, record.url) then
            table.remove(stack, i)
        end
    end

    stack[#stack + 1] = record
    return stack
end

local function remove_live_entry(id, url)
    local stack = teleporter_stacks_by_id[id]
    if not stack then
        return nil, nil
    end

    local removed = nil
    for i = #stack, 1, -1 do
        if url_equals(stack[i].url, url) then
            removed = table.remove(stack, i)
            break
        end
    end

    if not next(stack) then
        teleporter_stacks_by_id[id] = nil
        return removed, nil
    end

    return removed, stack[#stack]
end

local function store_static_by_pair(entry)
    if not entry.pair_id then return end
    -- Store under string key
    local pair_key = entry.pair_id
    local bucket = static_teleporters_by_pair[pair_key]
    if not bucket then
        bucket = {}
        static_teleporters_by_pair[pair_key] = bucket
    end
    bucket[entry.id] = entry
    -- Also store under hash key so hash-based lookups work
    -- (teleporter script properties resolve as hashes, not strings)
    if type(pair_key) == "string" and pair_key ~= "" then
        local h = hash(pair_key)
        if not static_teleporters_by_pair[h] then
            static_teleporters_by_pair[h] = {}
        end
        static_teleporters_by_pair[h][entry.id] = entry
    end
end

local function entry_is_available(entry)
    if not entry then return false end
    if entry.enabled == false then return false end
    local required = normalize_id(entry.requires_flag)
    if required and required ~= "" then
        return Flags.has(required)
    end
    return true
end

local function get_room_world_offset(room_id)
    local rm = get_room_manager()
    if not rm or not rm.get_room_data then
        return nil, nil
    end

    local data = rm.get_room_data(room_id)
    if not data then
        return nil, nil
    end

    return require("mvtk.map.streaming.room_geometry").compute_spawn_xy(data)
end

local function is_teleporter_object(object, props)
    if type(object) ~= "table" then
        return false
    end

    props = props or object.properties or {}

    local explicit =
        normalize_object_type(object.type) or
        normalize_object_type(object.class) or
        normalize_object_type(object.className)
    if explicit == "teleporter" then
        return true
    end

    if normalize_object_type(props.object_type) == "teleporter" then
        return true
    end

    if props.teleporter_id ~= nil or props.pair_id ~= nil then
        return true
    end

    local template_file = tostring(props.template_file or ""):lower()
    if template_file:find("teleporter", 1, true) then
        return true
    end

    return normalize_object_type(object.name) == "teleporter"
end

local function resolve_local_position(map, object)
    local parser = get_tiled_parser()
    if not parser or not parser.tiled_to_defold then
        return nil
    end

    local map_height = (tonumber(map and map.height) or 0) * (tonumber(map and map.tileheight) or 0)
    local x, y = parser.tiled_to_defold(tonumber(object and object.x) or 0, tonumber(object and object.y) or 0, map_height)
    local width = tonumber(object and object.width) or 0
    local height = tonumber(object and object.height) or 0
    local is_point = object and (object.point or object.shape == "point")

    if not (object and (object.gid or object.polyline or object.polygon or is_point)) and width > 0 and height > 0 then
        y = y - height
    end

    if CollisionBox and CollisionBox.center_from_bottom_left then
        x, y = CollisionBox.center_from_bottom_left(x, y, width, height, width, height)
    else
        if width > 0 then
            x = x + (width * 0.5)
        end
        if height > 0 then
            y = y + (height * 0.5)
        end
    end

    return vmath.vector3(x, y, 0)
end

local function register_static_teleporter(room_id, map, object, props)
    props = props or object.properties or {}

    local id = normalize_id(props.teleporter_id or object.name or string.format("teleporter_%s_%s", tostring(room_id or "room"), tostring(object and object.id or "")))
    if not id or id == "" then
        return
    end

    local entry = {
        id = id,
        pair_id = normalize_id(props.pair_id),
        target_id = normalize_id(props.target_id),
        requires_flag = normalize_id(props.requires_flag),
        room_id = normalize_id(room_id) or tostring(room_id or ""),
        local_position = resolve_local_position(map, object),
        source_object_id = object and object.id or nil,
        loaded = false,
        enabled = true,
    }

    static_teleporters_by_id[id] = entry
    -- Also store under hash key so hash-based lookups work
    -- (teleporter script hash properties can't be reverse-looked-up at runtime)
    if type(id) == "string" and id ~= "" then
        static_teleporters_by_id[hash(id)] = entry
    end
    store_static_by_pair(entry)
    teleporter_mgr_log("static registered", describe_entry(entry),
        "source_object_id=", tostring(entry.source_object_id))
end

local function index_room_teleporters(room_id, module_path)
    local parser = get_tiled_parser()
    if not parser or not parser.load then
        teleporter_mgr_log("index skipped: parser unavailable", tostring(room_id), tostring(module_path))
        return
    end

    local ok_map, map = pcall(parser.load, module_path)
    if not ok_map or type(map) ~= "table" then
        teleporter_mgr_log("index failed", tostring(room_id), tostring(module_path),
            "ok=", tostring(ok_map), "map=", tostring(map))
        return
    end

    local count = 0
    for _, layer in ipairs(map.layers or {}) do
        if type(layer) == "table" and layer.type == "objectgroup" and type(layer.objects) == "table" then
            for _, object in ipairs(layer.objects) do
                local props = parser.extract_properties and parser.extract_properties(object.properties) or (object.properties or {})
                if is_teleporter_object(object, props) then
                    register_static_teleporter(room_id, map, object, props)
                    count = count + 1
                end
            end
        end
    end
    teleporter_mgr_log("indexed room", tostring(room_id), tostring(module_path),
        "teleporters=", tostring(count))
end

local function ensure_static_index()
    if static_index_ready then
        return
    end

    static_index_ready = true
    teleporter_mgr_log("Building static teleporter index...")

    local rooms = {}

    -- Primary: get rooms from tiled room registry
    local registry = get_tiled_room_registry()
    teleporter_mgr_log("registry=", tostring(registry ~= nil))
    if registry and registry.get_all_rooms then
        local found = registry.get_all_rooms()
        if type(found) == "table" then
            for room_id, module_path in pairs(found) do
                if module_path and module_path ~= "" then
                    rooms[room_id] = module_path
                end
            end
        end
    end

    local primary_count = 0
    for _ in pairs(rooms) do primary_count = primary_count + 1 end
    teleporter_mgr_log("primary scan found", primary_count, "rooms")

    -- Fallback: derive room IDs from rooms_config.lua factory table
    -- This ensures we find all rooms even if directory scanning failed
    if not next(rooms) then
        teleporter_mgr_log("primary scan empty, trying rooms_config fallback...")
        local ok_cfg, rooms_cfg = pcall(Util.require_config, "developer.config.rooms_config")
        teleporter_mgr_log("rooms_config loaded=", tostring(ok_cfg),
            "has_factories=", tostring(ok_cfg and rooms_cfg and type(rooms_cfg.factories) == "table"))
        if ok_cfg and rooms_cfg and type(rooms_cfg.factories) == "table" then
            for factory_key, _ in pairs(rooms_cfg.factories) do
                local room_id = Util.normalize_room_id(factory_key)
                if room_id and room_id ~= "" and not rooms[room_id] then
                    local module_path = "developer.assets.tiled.maps." .. room_id
                    rooms[room_id] = module_path
                    teleporter_mgr_log("fallback room:", room_id, "->", module_path)
                end
            end
        end
    end

    for room_id, module_path in pairs(rooms) do
        index_room_teleporters(room_id, module_path)
    end

    local total_static = 0
    for _ in pairs(static_teleporters_by_id) do total_static = total_static + 1 end
    teleporter_mgr_log("Static index built. Total teleporters indexed:", total_static)
    for id, e in pairs(static_teleporters_by_id) do
        teleporter_mgr_log(id, "room=", tostring(e.room_id), "pair=", tostring(e.pair_id),
            "target=", tostring(e.target_id), "local_pos=", tostring(e.local_position))
    end
end

function M.register(entry)
    if not entry then return nil end
    local id = normalize_id(entry.id) or tostring(entry.id or "")
    if id == "" then return nil end
    local pair_id = normalize_id(entry.pair_id)
    local target_id = normalize_id(entry.target_id)

    local record = {
        id = id,
        pair_id = pair_id,
        target_id = target_id,
        requires_flag = normalize_id(entry.requires_flag),
        url = entry.url,
        position = entry.position,
        room_id = entry.room_id,
        enabled = entry.enabled ~= false,
    }

    local previous = teleporters_by_id[id]
    if previous then
        teleporter_mgr_log("live superseding existing", describe_entry(previous),
            "new_url=", tostring(record.url))
        remove_by_pair(previous)
    end
    push_live_entry(id, record)
    teleporters_by_id[id] = record
    store_by_pair(record)
    teleporter_mgr_log("live registered", describe_entry(record))
    return id
end

function M.unregister(id, url)
    local key = normalize_id(id) or tostring(id or "")
    if key == "" then
        teleporter_mgr_log("unregister skipped: empty id", tostring(id))
        return
    end
    local entry = teleporters_by_id[key]
    if not entry then
        teleporter_mgr_log("unregister missed", tostring(key))
        return
    end

    local caller_url = url
    if not caller_url then
        local ok_url, resolved_url = pcall(msg.url)
        if ok_url then
            caller_url = resolved_url
        end
    end

    local removed, fallback = remove_live_entry(key, caller_url)
    if not removed then
        teleporter_mgr_log("unregister ignored: caller does not own id", tostring(key),
            "caller=", tostring(caller_url), "active=", describe_entry(entry))
        return
    end

    if url_equals(entry.url, removed.url) then
        remove_by_pair(entry)
        if fallback then
            teleporters_by_id[key] = fallback
            store_by_pair(fallback)
            teleporter_mgr_log("live unregistered and restored fallback",
                "removed=", describe_entry(removed), "fallback=", describe_entry(fallback))
        else
            teleporters_by_id[key] = nil
            teleporter_mgr_log("live unregistered", describe_entry(removed))
        end
    else
        teleporter_mgr_log("live unregistered inactive duplicate", describe_entry(removed),
            "active=", describe_entry(entry))
    end
end

function M.update_position(id, pos)
    local key = normalize_id(id) or tostring(id or "")
    local entry = teleporters_by_id[key]
    if entry and pos then
        entry.position = pos
    end
end

function M.get_by_id(id)
    local key = normalize_id(id) or tostring(id or "")
    local entry = teleporters_by_id[key]
    if entry and entry_is_available(entry) then
        teleporter_mgr_log("get_by_id live hit", tostring(id), describe_entry(entry))
        return entry
    end
    teleporter_mgr_log("get_by_id live miss", tostring(id), "key=", tostring(key),
        "entry=", describe_entry(entry), "available=", tostring(entry and entry_is_available(entry)))
    return nil
end

function M.get_static_by_id(id)
    local key = normalize_id(id) or tostring(id or "")
    if key == "" then return nil end
    ensure_static_index()
    local entry = static_teleporters_by_id[key]
    -- Hash userdata from script properties may not match string keys in tables.
    -- Fall back to hash comparison when direct lookup fails.
    if not entry then
        for static_id, static_entry in pairs(static_teleporters_by_id) do
            if static_id == key then
                entry = static_entry
                break
            end
            -- Compare hash of string key to the hash key
            if type(static_id) == "string" and type(key) ~= "string" then
                if hash(static_id) == key then
                    entry = static_entry
                    break
                end
            elseif type(key) == "string" and type(static_id) ~= "string" then
                if hash(key) == static_id then
                    entry = static_entry
                    break
                end
            end
        end
    end
    if entry and entry_is_available(entry) then
        teleporter_mgr_log("get_static_by_id hit", tostring(id), describe_entry(entry))
        return entry
    end
    teleporter_mgr_log("get_static_by_id miss", tostring(id), "key=", tostring(key),
        "entry=", describe_entry(entry), "available=", tostring(entry and entry_is_available(entry)))
    return nil
end

function M.get_position(entry)
    if not entry then return nil end
    if entry.url then
        local go_url = object_url(entry.url)
        if go_exists_safe(go_url) then
            local pos = get_world_position_safe(go_url)
            if pos then
                teleporter_mgr_log("get_position live url", describe_entry(entry),
                    "go=", tostring(go_url), "resolved=", fmt_pos(pos))
                return pos
            end
        end
        teleporter_mgr_log("get_position live url unavailable", describe_entry(entry),
            "go=", tostring(go_url))
    end
    if entry.position then
        teleporter_mgr_log("get_position cached", describe_entry(entry), "resolved=", fmt_pos(entry.position))
        return entry.position
    end
    if entry.local_position and entry.room_id then
        local base_x, base_y = get_room_world_offset(entry.room_id)
        if base_x ~= nil and base_y ~= nil then
            local pos = vmath.vector3(
                base_x + (entry.local_position.x or 0),
                base_y + (entry.local_position.y or 0),
                entry.local_position.z or 0
            )
            teleporter_mgr_log("get_position static", describe_entry(entry),
                "base=", string.format("(%.1f, %.1f)", base_x, base_y),
                "resolved=", fmt_pos(pos))
            return pos
        end
        teleporter_mgr_log("get_position static failed: room offset missing",
            describe_entry(entry))
    end
    teleporter_mgr_log("get_position failed", describe_entry(entry))
    return nil
end

function M.find_destination(entry)
    if not entry then return nil end
    teleporter_mgr_log("find_destination for", tostring(entry.id),
        "target_id=", tostring(entry.target_id), "pair_id=", tostring(entry.pair_id))
    if entry.target_id then
        local direct = M.get_by_id(entry.target_id)
        teleporter_mgr_log("live lookup target_id=", tostring(entry.target_id), "found=", tostring(direct ~= nil))
        if direct and direct.id ~= entry.id then
            teleporter_mgr_log("find_destination selected live target", describe_entry(direct))
            return direct
        end
        local static = M.get_static_by_id(entry.target_id)
        teleporter_mgr_log("static lookup target_id=", tostring(entry.target_id), "found=", tostring(static ~= nil))
        if static and static.id ~= entry.id then
            local selected = M.get_by_id(static.id) or static
            teleporter_mgr_log("find_destination selected static target", describe_entry(selected))
            return selected
        end
    end
    if entry.pair_id then
        local bucket = teleporters_by_pair[entry.pair_id]
        teleporter_mgr_log("pair lookup pair_id=", tostring(entry.pair_id), "bucket=", tostring(bucket ~= nil))
        if bucket then
            for id, dest in pairs(bucket) do
                if id ~= entry.id then
                    teleporter_mgr_log("find_destination selected live pair", describe_entry(dest))
                    return dest
                end
            end
        end
        ensure_static_index()
        -- Try direct and hash-comparison based lookup for static pairs
        local static_bucket = static_teleporters_by_pair[entry.pair_id]
        if not static_bucket then
            for pair_key, pair_bucket in pairs(static_teleporters_by_pair) do
                if type(pair_key) == "string" and type(entry.pair_id) ~= "string" then
                    if hash(pair_key) == entry.pair_id then
                        static_bucket = pair_bucket
                        break
                    end
                elseif type(entry.pair_id) == "string" and type(pair_key) ~= "string" then
                    if hash(entry.pair_id) == pair_key then
                        static_bucket = pair_bucket
                        break
                    end
                end
            end
        end
        teleporter_mgr_log("static pair lookup pair_id=", tostring(entry.pair_id),
            "found=", tostring(static_bucket ~= nil))
        if static_bucket then
            for id, dest in pairs(static_bucket) do
                -- Compare IDs using hash equality to handle hash-vs-string
                local same = (id == entry.id)
                if not same and type(id) ~= type(entry.id) then
                    if type(id) == "string" then
                        same = hash(id) == entry.id
                    else
                        same = type(entry.id) == "string" and hash(entry.id) == id
                    end
                end
                if not same then
                    local selected = M.get_by_id(id) or dest
                    teleporter_mgr_log("find_destination selected static pair", describe_entry(selected))
                    return selected
                end
            end
        end
    end
    teleporter_mgr_log("RESULT: no destination found")
    return nil
end

function M.can_teleport(actor_url, cooldown)
    if not actor_url then
        teleporter_mgr_log("can_teleport false: missing actor")
        return false
    end
    local key = url_key(actor_url)
    if not key then
        teleporter_mgr_log("can_teleport false: actor key failed", tostring(actor_url))
        return false
    end
    local last = recent_by_actor[key]
    local cd = tonumber(cooldown) or 0
    if last and cd > 0 and (Time.gettime() - last) < cd then
        teleporter_mgr_log("can_teleport false: cooldown", tostring(actor_url),
            "elapsed=", tostring(Time.gettime() - last), "cooldown=", tostring(cd))
        return false
    end
    teleporter_mgr_log("can_teleport true", tostring(actor_url), "cooldown=", tostring(cd))
    return true
end

function M.mark_teleport(actor_url)
    local key = url_key(actor_url)
    if key then
        recent_by_actor[key] = Time.gettime()
        teleporter_mgr_log("mark_teleport", tostring(actor_url), "key=", tostring(key),
            "time=", tostring(recent_by_actor[key]))
    else
        teleporter_mgr_log("mark_teleport skipped: actor key failed", tostring(actor_url))
    end
end

return M
