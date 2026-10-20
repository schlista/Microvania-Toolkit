-- developer/tools/content_relationships.lua
--
-- Shared authored-content index and relationship validator for Tiled exports.
-- This module is editor/headless friendly: it only inspects Lua tables and does
-- not call Defold runtime APIs.

local Objects = require "hooks.core.tiled_objects"
local Properties = require "mvtk.tiled.property_flattener"
local Proto = require "mvtk.editor.proto_emit"
local Native = require "developer.tools.object_references"

local M = {}

local function trim(value)
    if value == nil then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end

local function nonempty(value)
    local s = trim(value)
    return s ~= "" and s or nil
end

local function add_to_bucket(index, namespace, key, object)
    if not key or key == "" then return end
    index.definitions[namespace] = index.definitions[namespace] or {}
    local bucket = index.definitions[namespace][key]
    if not bucket then
        bucket = {}
        index.definitions[namespace][key] = bucket
    end
    bucket[#bucket + 1] = object
end

local function add_reference(index, object, namespace, key, property, scope, opts)
    if (not key or key == "") and not (opts and opts.optional) then return end
    index.references[#index.references + 1] = {
        from = object,
        namespace = namespace,
        key = key,
        property = property,
        scope = scope or "global",
        optional = opts and opts.optional == true or false,
    }
end

local function diagnostic(out, severity, code, object, property, message, fix)
    out[#out + 1] = {
        severity = severity,
        code = code,
        file = object and object.file or nil,
        room = object and object.room or nil,
        layer = object and object.layer or nil,
        object_id = object and object.object_id or nil,
        object_type = object and object.type or nil,
        property = property,
        message = message,
        fix = fix,
    }
end

local function object_label(object)
    if not object then return "<unknown>" end
    return string.format("%s:%s:%s id=%s",
        tostring(object.file or object.room or "?"),
        tostring(object.layer or "?"),
        tostring(object.type or "?"),
        tostring(object.object_id or "?"))
end

local function walk_layers(layers, visitor, parent_path, inherited_visible)
    inherited_visible = inherited_visible ~= false
    for _, layer in ipairs(layers or {}) do
        if type(layer) == "table" then
            local name = tostring(layer.name or "<unnamed>")
            local path = parent_path and (parent_path .. "/" .. name) or name
            local visible = inherited_visible and layer.visible ~= false
            if layer.type == "objectgroup" and type(layer.objects) == "table" then
                for _, object in ipairs(layer.objects) do
                    if type(object) == "table" then
                        visitor(object, layer, {
                            path = path,
                            visible = visible and object.visible ~= false,
                            top_level = parent_path == nil,
                        })
                    end
                end
            end
            if type(layer.layers) == "table" then
                walk_layers(layer.layers, visitor, path, visible)
            end
        end
    end
end

local function make_object(index, room, map, file, object, layer, state)
    local props = Properties.flatten(object.properties or {})
    local object_type = Objects.resolve_object_type(object, index.known_types)
        or Objects.resolve_object_type({ name = object.name, properties = props }, index.known_types)
        or object.type
        or "unknown"
    local object_id = object.id
    local instance_id = Proto.generated_object_id(room, object_type, object_id)
    local record = {
        room = room,
        file = file,
        layer = state.path,
        top_level = state.top_level,
        visible = state.visible,
        object_id = object_id,
        type = object_type,
        name = object.name,
        instance_id = instance_id,
        properties = props,
        raw = object,
        map = map,
    }
    index.objects[#index.objects + 1] = record
    index.by_instance_id[instance_id] = record
    index.by_room[room] = index.by_room[room] or {}
    index.by_room[room][#index.by_room[room] + 1] = record
    return record
end

local function first_id(props, names)
    for _, name in ipairs(names) do
        local value = nonempty(props[name])
        if value then return value, name end
    end
    return nil, nil
end

local function object_default_id(object, prefix)
    -- The baker's `or` fallback treats an explicitly blank property/name as
    -- present; the component then falls back to its baked gameobject ID.
    if object.properties[prefix .. "_id"] == "" then return object.instance_id end
    local id = nonempty(object.properties[prefix .. "_id"])
    if id then return id end
    id = nonempty(object.name)
    if id then return id end
    if object.name == "" then return object.instance_id end
    return string.format("%s_%s_%s", prefix, tostring(object.room), tostring(object.object_id))
end

local function index_object(index, object)
    local props = object.properties
    local t = object.type

    if t == "teleporter" then
        local id = object_default_id(object, "teleporter")
        object.relationship_ids = object.relationship_ids or {}
        object.relationship_ids.teleporter_id = id
        add_to_bucket(index, "teleporter", id, object)
        add_reference(index, object, "teleporter", nonempty(props.target_id), "target_id", "global")
        if nonempty(props.pair_id) then
            add_to_bucket(index, "teleporter_pair", nonempty(props.pair_id), object)
        end
    elseif t == "timed_door" then
        add_to_bucket(index, "trigger_channel", object_default_id(object, "door"), object)
    elseif t == "hazard" then
        add_to_bucket(index, "trigger_channel", object_default_id(object, "hazard"), object)
    elseif t == "elevator" then
        local elevator_id = nonempty(props.elevator_id)
        add_to_bucket(index, "trigger_channel", elevator_id, object)
        if nonempty(props.trigger_id) ~= elevator_id then
            add_to_bucket(index, "trigger_channel", nonempty(props.trigger_id), object)
        end
    elseif t == "lever" then
        add_reference(index, object, "trigger_channel",
            nonempty(props.target_id), "target_id")
        -- A flag-only lever has an authored effect without a trigger channel.
        if not nonempty(props.target_id) and not nonempty(props.set_flag_on) then
            add_reference(index, object, "trigger_channel",
                nil, "target_id", "global", { optional = true })
        end
    elseif t == "pressure_plate" then
        local target = nonempty(props.target_id) or object_default_id(object, "plate")
        add_reference(index, object, "trigger_channel",
            target, nonempty(props.target_id) and "target_id" or "plate_id")
    end

    if t == "boss" then
        local boss_id = first_id(props, { "boss_id", "boss_tag" }) or object.instance_id
        object.relationship_ids = object.relationship_ids or {}
        object.relationship_ids.boss_id = boss_id
        add_to_bucket(index, "boss", boss_id, object)
        if nonempty(props.boss_tag) and nonempty(props.boss_tag) ~= boss_id then
            add_to_bucket(index, "boss", nonempty(props.boss_tag), object)
        end
        add_to_bucket(index, "boss_selector", first_id(props,{"boss_preset","boss_type"}), object)
        add_reference(index, object, "boss_arena", nonempty(props.arena_id), "arena_id", "global")
    elseif t == "boss_arena" then
        add_to_bucket(index, "boss_arena", nonempty(props.arena_id) or ("arena_" .. object.room), object)
        add_reference(index, object, "boss", nonempty(props.boss_id), "boss_id", "global")
    elseif t == "boss_phase" then
        add_to_bucket(index, "boss_phase", first_id(props, { "phase_id" }) or object.instance_id, object)
        add_reference(index, object, "boss", nonempty(props.boss_id), "boss_id", "global")
        add_reference(index, object, "boss_arena", nonempty(props.arena_id), "arena_id")
    elseif t == "boss_phase_trigger" then
        add_to_bucket(index, "boss_phase_trigger", first_id(props, { "trigger_id" }), object)
        add_reference(index, object, "boss", nonempty(props.boss_id), "boss_id", "global")
        add_reference(index, object, "boss_arena", nonempty(props.arena_id), "arena_id")
    elseif t == "boss_weak_point" then
        add_to_bucket(index, "boss_weak_point", first_id(props, { "point_id" }), object)
        add_reference(index, object, "boss", nonempty(props.boss_id), "boss_id", "global")
    end

    if t == "boss_phase" or t == "boss_phase_trigger" or t == "boss_weak_point" or t == "boss_arena" then
        if not nonempty(props.boss_id) then
            local selector=first_id(props,{"boss_preset","boss_type"})
            if selector and selector:lower() ~= "none" then
                add_reference(index,object,"boss_selector",selector,"boss_preset","room")
            end
        end
    end

    local persistent_field = ({chest = "chest_id", breakable_wall = "wall_id", save_point = "save_id"})[t]
    if persistent_field then
        object.persistent_id = nonempty(props[persistent_field])
            or (t == "save_point" and nonempty(object.name)) or object.instance_id
        add_to_bucket(index, "persistent_" .. persistent_field, object.persistent_id, object)
    elseif t == "boss" then
        object.persistent_id = object.relationship_ids.boss_id
    end
    for _, field in ipairs({"destination_room", "destination_room_id", "target_room", "target_room_id"}) do
        add_reference(index, object, "room", nonempty(props[field]), field)
    end

    for _, field in ipairs({ "ability_id", "require_ability", "requires_ability", "reward_ability" }) do
        local ability_id = nonempty(props[field])
        if ability_id and ability_id:lower() ~= "none" then
            add_reference(index, object, "ability", ability_id, field, "global")
        end
    end
    for _, field in ipairs({ "require_key", "key_id", "required_key" }) do
        local key_id = nonempty(props[field])
        if key_id and key_id:lower() ~= "none" then
            add_reference(index, object, "key", key_id, field, "global")
        end
    end
    if t == "dialogue_trigger" or t == "npc" or t == "sign" or t == "lore_item" or t == "hint_stone" then
        local dialogue_id = nonempty(props.dialogue_id)
        if dialogue_id then
            add_reference(index, object, "dialogue", dialogue_id, "dialogue_id", "global")
        elseif t == "dialogue_trigger" then
            add_reference(index, object, "dialogue", nil, "dialogue_id", "global", { optional = true })
        end
    end
end

function M.build_index(maps, opts)
    opts = opts or {}
    local index = {
        version = 1,
        rooms = {},
        objects = {},
        by_room = {},
        by_instance_id = {},
        definitions = {},
        references = {},
        diagnostics = {},
        normalized_maps = {},
        room_set = {},
        known_types = opts.known_types,
    }
    if not index.known_types and type(Objects.load_object_type_set) == "function" then
        local ok, set = pcall(Objects.load_object_type_set)
        if ok and type(set) == "table" then index.known_types = set end
    end

    for room in pairs(maps or {}) do index.rooms[#index.rooms + 1] = room end
    table.sort(index.rooms)
    for _, room in ipairs(index.rooms) do
        local entry = maps[room]
        local map = entry and entry.map or entry
        local file = entry and entry.file or ("developer/assets/tiled/maps/" .. tostring(room) .. ".lua")
        local native_diagnostics
        map, native_diagnostics = Native.normalize(map, room)
        index.normalized_maps[room] = map
        index.room_set[room] = true
        for _, d in ipairs(native_diagnostics) do d.file = file; index.diagnostics[#index.diagnostics+1] = d end
        walk_layers(map and map.layers, function(object, layer, state)
            local record = make_object(index, room, map, file, object, layer, state)
            if record.visible then index_object(index, record) end
        end)
    end

    return index
end

local function load_config_set(config, field)
    local out = {}
    if type(config) ~= "table" then return out end
    local source = field and config[field] or config
    if type(source) ~= "table" then return out end
    for key in pairs(source) do out[tostring(key)] = true end
    return out
end

local function key_set_from_config(config)
    local out = {}
    local ok_keyids, KeyIds = pcall(require, "mvtk.core.key_ids")
    if ok_keyids and KeyIds and type(KeyIds.canonical_ids) == "function" then
        for _, id in ipairs(KeyIds.canonical_ids()) do out[id] = true end
        for authored, canonical in pairs(KeyIds.AUTHORED_TO_CANONICAL or {}) do
            if canonical and canonical ~= "" then out[tostring(authored)] = true end
        end
    end
    if type(config) == "table" then
        for key in pairs(config) do out[tostring(key)] = true end
    end
    return out
end

local function bucket_for(index, ref)
    return index.definitions[ref.namespace] and index.definitions[ref.namespace][ref.key] or nil
end

local function has_same_room(bucket, room)
    local count = 0
    local first
    for _, object in ipairs(bucket or {}) do
        if object.room == room then
            count = count + 1
            first = first or object
        end
    end
    return count, first
end

function M.validate(index, opts)
    opts = opts or {}
    local diagnostics = {}
    for _, d in ipairs(index.diagnostics or {}) do diagnostics[#diagnostics+1] = d end
    local ability_set = opts.abilities or load_config_set(opts.ability_config, "abilities")
    local key_set = opts.keys or key_set_from_config(opts.key_config)
    local dialogue_set = opts.dialogues or load_config_set(opts.dialogue_config)

    for _, object in ipairs(index.objects) do
        if object.visible and object.type == "teleporter" and
            (object.properties.teleporter_id == "" or
            (object.properties.teleporter_id == nil and object.name == "")) then
            diagnostic(diagnostics,"error","missing_teleporter_id",object,"teleporter_id",
                "An explicitly blank teleporter identity is absent from the unloaded-room destination registry.",
                "Set a unique teleporter_id, or select this teleporter with a native object reference and export again.")
        end
        if object.visible and object.type == "boss_phase_trigger" then
            local phase = object.properties.phase == nil and 1 or tonumber(object.properties.phase)
            if not phase or phase < 1 or phase ~= math.floor(phase) then
                diagnostic(diagnostics, "error", "invalid_boss_phase", object, "phase",
                    "Boss phase must be a positive integer.", "Choose a phase number from the boss or arena configuration.")
            end
            -- BossSetup collects matching room-local phase markers in order.
            -- Explicit authored phases override a preset's fallback phase list.
            local p=object.properties
            local id=nonempty(p.boss_id)
            local candidates=id and index.definitions.boss and index.definitions.boss[id]
            local selector=first_id(p,{"boss_preset","boss_type"})
            if not id and selector then
                candidates={}
                for _,boss in ipairs((index.definitions.boss_selector or {})[selector] or {}) do
                    if boss.room==object.room then candidates[#candidates+1]=boss end
                end
            end
            if candidates and #candidates==1 then
                local boss=candidates[1]
                local bp=boss.properties
                local boss_id=boss.relationship_ids.boss_id
                local preset=first_id(bp,{"boss_preset","boss_type"})
                local count=0
                for _,marker in ipairs(index.by_room[boss.room] or {}) do
                    local mp=marker.properties
                    if marker.visible and marker.type=="boss_phase"
                        and (not nonempty(mp.boss_id) or mp.boss_id==boss_id)
                        and (not first_id(mp,{"boss_preset","boss_type"}) or first_id(mp,{"boss_preset","boss_type"})==preset)
                        and (not nonempty(mp.arena_id) or mp.arena_id==bp.arena_id) then count=count+1 end
                end
                if count==0 and nonempty(bp.attack_pattern_ids) then count=1 end
                local config=preset and opts.boss_config and opts.boss_config[preset]
                if count==0 and config and type(config.phases)=="table" then count=#config.phases end
                if phase and count>0 and phase>count and not nonempty(bp.phase_config) then
                    diagnostic(diagnostics,"error","missing_boss_phase",object,"phase",
                        string.format("Boss '%s' has %d phase(s), but this trigger requests phase %d.",boss_id,count,phase),
                        "Choose an existing phase number or add a boss_phase for this encounter.")
                end
            end
            if nonempty(object.properties.phase_id) then
                diagnostic(diagnostics, "warning", "unused_phase_id", object, "phase_id",
                    "Phase triggers use the numeric phase property; phase_id is not consumed by the runtime.",
                    "Set phase and a boss_id/boss_ref or arena_id/arena_ref.")
            end
        end
    end

    for namespace, definitions in pairs(index.definitions or {}) do
        for key, bucket in pairs(definitions) do
            if namespace ~= "teleporter_pair" and #bucket > 1 then
                local global_namespace = namespace == "teleporter"
                    or namespace == "boss"
                    or namespace == "boss_arena"
                    or namespace == "boss_phase"
                    or namespace:match("^persistent_") ~= nil
                if global_namespace then
                    for _, object in ipairs(bucket) do
                        diagnostic(diagnostics, "error", "duplicate_" .. namespace, object, nil,
                            string.format("%s '%s' is defined by multiple objects; first also at %s",
                                namespace, tostring(key), object_label(bucket[1])),
                            "Give each globally referenced object a unique ID.")
                    end
                end
            end
        end
    end

    for _, ref in ipairs(index.references or {}) do
        local from = ref.from
        if ref.key == nil or ref.key == "" then
            if ref.optional then
                diagnostic(diagnostics, "warning", "blank_reference", from, ref.property,
                    string.format("%s has no %s; runtime may fall back to a broadcast or generated ID.",
                        tostring(from.type), tostring(ref.property)),
                    "Set an explicit ID when this object should connect to another authored object.")
            end
        elseif ref.namespace == "ability" then
            if not (opts.abilities or opts.ability_config) then
                diagnostic(diagnostics,"warning","ability_index_unavailable",from,ref.property,
                    "Ability definitions were not loaded; this reference is unverified.","Run Prepare & Check in the project.")
            end
            if (opts.abilities or opts.ability_config) and not ability_set[ref.key] then
                diagnostic(diagnostics, "error", "missing_ability", from, ref.property,
                    string.format("Ability '%s' is not defined in developer/config/abilities.lua.", tostring(ref.key)),
                    "Choose an ability ID from developer/config/abilities.lua.")
            end
        elseif ref.namespace == "key" then
            if next(key_set) ~= nil and not key_set[ref.key] then
                diagnostic(diagnostics, "warning", "unknown_key", from, ref.property,
                    string.format("Key '%s' is not a built-in key ID.", tostring(ref.key)),
                    "Use a built-in key ID or confirm the matching custom item is granted elsewhere.")
            end
        elseif ref.namespace == "dialogue" then
            if not (opts.dialogues or opts.dialogue_config) then
                diagnostic(diagnostics,"warning","dialogue_index_unavailable",from,ref.property,
                    "Dialogue definitions were not loaded; this reference is unverified.","Run Prepare & Check in the project.")
            end
            if (opts.dialogues or opts.dialogue_config) and not dialogue_set[ref.key] then
                diagnostic(diagnostics, "error", "missing_dialogue", from, ref.property,
                    string.format("Dialogue '%s' is not defined in developer/config/narrative/dialogues.lua.", tostring(ref.key)),
                    "Add the dialogue sequence or choose an existing dialogue ID.")
            end
        elseif ref.namespace == "room" then
            if not index.by_room[ref.key] and not (index.room_set and index.room_set[ref.key]) then
                diagnostic(diagnostics, "error", "missing_room", from, ref.property,
                    "Destination room '" .. ref.key .. "' has no Tiled export.", "Choose an exported room ID.")
            end
        else
            local bucket = bucket_for(index, ref)
            local configured_arena = ref.namespace == "boss_arena" and opts.arena_config
                and ((opts.arena_config.arenas or opts.arena_config)[ref.key])
            if (not bucket or #bucket == 0) and configured_arena then
                bucket = {{room=from.room, type="configured_arena"}}
            end
            if (not bucket or #bucket == 0) and ref.namespace == "teleporter"
                and nonempty(from.properties.pair_id)
                and #(index.definitions.teleporter_pair[from.properties.pair_id] or {}) == 2 then
                diagnostic(diagnostics,"warning","teleporter_target_fallback",from,ref.property,
                    "The explicit target is missing; runtime falls back to the paired endpoint.",
                    "Correct target_id or clear it to use pair_id intentionally.")
            elseif not bucket or #bucket == 0 then
                diagnostic(diagnostics, "error", "missing_" .. ref.namespace, from, ref.property,
                    string.format("%s '%s' does not match any authored object.", tostring(ref.namespace), tostring(ref.key)),
                    "Fix the ID or add the referenced object in Tiled.")
            elseif ref.scope == "room" then
                local count = has_same_room(bucket, from.room)
                if count == 0 then
                    diagnostic(diagnostics, "error", "cross_room_" .. ref.namespace, from, ref.property,
                        string.format("%s '%s' exists, but not in room '%s'.", tostring(ref.namespace), tostring(ref.key), tostring(from.room)),
                        "Room-local trigger targets should live in the same Tiled room.")
                elseif count > 1 then
                    diagnostic(diagnostics, "error", "ambiguous_" .. ref.namespace, from, ref.property,
                        string.format("%s '%s' matches %d objects in room '%s'.", tostring(ref.namespace), tostring(ref.key), count, tostring(from.room)),
                        "Use a unique target ID in this room.")
                end
            elseif ref.namespace == "teleporter" and opts.published_rooms then
                for _,target in ipairs(bucket) do
                    if opts.published_rooms[from.room] and not opts.published_rooms[target.room] then
                        diagnostic(diagnostics,"error","unpublished_destination_room",from,ref.property,
                            "The teleporter destination room '" .. target.room .. "' is absent from the published layout.",
                            "Place the destination room in Layout Editor before exporting.")
                    end
                end
            elseif ref.namespace == "trigger_channel" then
                local local_count = has_same_room(bucket, from.room)
                if local_count == 0 then
                    local persistent = false
                    for _, target in ipairs(bucket) do if target.type == "elevator" then persistent = true end end
                    if not persistent then
                        diagnostic(diagnostics, "warning", "cross_room_trigger_channel", from, ref.property,
                            "This channel only has listeners in other rooms; it works only while those rooms are loaded.",
                            "Playtest streaming boundaries or use a persistent elevator controller.")
                    end
                end
            elseif #bucket > 1 then
                diagnostic(diagnostics, "error", "ambiguous_" .. ref.namespace, from, ref.property,
                    string.format("%s '%s' matches %d authored objects.", tostring(ref.namespace), tostring(ref.key), #bucket),
                    "Use a unique referenced ID.")
            end
        end
    end

    for pair_id, bucket in pairs(index.definitions.teleporter_pair or {}) do
        if #bucket ~= 2 then
            local used=false
            for _,object in ipairs(bucket) do
                local target=nonempty(object.properties.target_id)
                local direct=target and index.definitions.teleporter and index.definitions.teleporter[target]
                if object.properties.one_way ~= true and not (direct and #direct==1) then used=true end
            end
            for _, object in ipairs(bucket) do
                diagnostic(diagnostics, used and "error" or "warning", "teleporter_pair_cardinality", object, "pair_id",
                    string.format("Teleporter pair '%s' has %d endpoint(s); it must have exactly 2.", tostring(pair_id), #bucket),
                    "Place exactly two teleporters with the same pair_id, or use target_id.")
            end
        elseif opts.published_rooms then
            for i,object in ipairs(bucket) do
                local target=nonempty(object.properties.target_id)
                local direct=target and index.definitions.teleporter and index.definitions.teleporter[target]
                local destination=bucket[3-i]
                if object.properties.one_way~=true and not direct and opts.published_rooms[object.room]
                    and not opts.published_rooms[destination.room] then
                    diagnostic(diagnostics,"error","unpublished_destination_room",object,"pair_id",
                        "The paired destination room '" .. destination.room .. "' is absent from the published layout.",
                        "Place the destination room in Layout Editor before exporting.")
                end
            end
        end
    end

    table.sort(diagnostics, function(a, b)
        local left = table.concat({
            tostring(a.severity), tostring(a.code), tostring(a.file),
            tostring(a.room), tostring(a.layer), tostring(a.object_id), tostring(a.property)
        }, "\t")
        local right = table.concat({
            tostring(b.severity), tostring(b.code), tostring(b.file),
            tostring(b.room), tostring(b.layer), tostring(b.object_id), tostring(b.property)
        }, "\t")
        return left < right
    end)
    return diagnostics
end

function M.format_diagnostic(d)
    local where = string.format("%s room=%s layer=%s object=%s",
        tostring(d.file or "?"), tostring(d.room or "?"),
        tostring(d.layer or "?"), tostring(d.object_id or "?"))
    local prop = d.property and (" property=" .. tostring(d.property)) or ""
    local fix = d.fix and (" Fix: " .. tostring(d.fix)) or ""
    return string.format("[%s] %s %s%s: %s%s",
        tostring(d.severity or "info"):upper(),
        tostring(d.code or "unknown"),
        where,
        prop,
        tostring(d.message or ""),
        fix)
end

function M.summary(diagnostics)
    local summary = { errors = 0, warnings = 0, info = 0, total = #(diagnostics or {}) }
    for _, d in ipairs(diagnostics or {}) do
        if d.severity == "error" then summary.errors = summary.errors + 1
        elseif d.severity == "warning" then summary.warnings = summary.warnings + 1
        else summary.info = summary.info + 1 end
    end
    return summary
end

return M
