-- hooks/core/bake_audit.lua
--
-- Standalone post-bake audit for Tiled template objects and painted grapple
-- strips. Resource reads are supplied by callers so plain Lua tests can audit
-- the same collection and collision data without writing authored rooms.

local GrappleLayerBake = require "hooks.core.grapple_layer_bake"
local ResourceText = require "mvtk.editor.resource_text"
local RetiredTypes = require "mvtk.tiled.retired_types"
local PropertyFlattener = require "mvtk.tiled.property_flattener"
local M = {}

local DEFAULT_TEMPLATE_ALIASES = {
    ability_pickup = { ability = true },
    key = { collectible = true },
    map_fragment = { collectible = true },
    player_start = { spawn_point = true },
    solid_box = { collision_box = true },
    solid_slope = { collision_slope = true },
    boss_phase_trigger = { boss_phase_trigger = true },
    moving_platform = { moving_platform = true, platform = true },
    elevator = { elevator = true },
    elevator_node = { elevator_node = true },
    secret_area = { secret = true },
    horizontal_platform = { platform = true },
    vertical_platform = { platform = true },
    path_platform = { platform = true },
    rail_elevator = { joint_platform = true },
}

M.DEFAULT_TEMPLATE_ALIASES = DEFAULT_TEMPLATE_ALIASES

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalize_type(value)
    local normalized = trim(value):lower()
    normalized = normalized:gsub("[%s%-]+", "_"):gsub("_+", "_")
    normalized = normalized:gsub("^_+", ""):gsub("_+$", "")
    if normalized == "" then return nil end
    return normalized
end

local function normalize_set(values)
    local set = {}
    if type(values) ~= "table" then return set end
    for key, value in pairs(values) do
        local item = nil
        if type(key) == "number" then
            item = value
        elseif value then
            item = key
        end
        item = normalize_type(item)
        if item then set[item] = true end
    end
    return set
end

local function copy_aliases(extra_aliases)
    local aliases = {}

    local function merge(source)
        if type(source) ~= "table" then return end
        for template_name, allowed_values in pairs(source) do
            local template_type = normalize_type(template_name)
            if template_type then
                local allowed = aliases[template_type] or {}
                if type(allowed_values) == "string" then
                    local resolved = normalize_type(allowed_values)
                    if resolved then allowed[resolved] = true end
                elseif type(allowed_values) == "table" then
                    for resolved in pairs(normalize_set(allowed_values)) do
                        allowed[resolved] = true
                    end
                end
                aliases[template_type] = allowed
            end
        end
    end

    merge(DEFAULT_TEMPLATE_ALIASES)
    merge(extra_aliases)
    return aliases
end

local function is_visible(value)
    if value == false or value == 0 then return false end
    if type(value) == "string" and value:lower() == "false" then return false end
    return true
end

local function canonical_object_id(value)
    if value == nil then return nil end
    local text = trim(value)
    if text == "" then return nil end

    -- Editor-loaded numeric fields can arrive as Java-style decimal strings.
    -- Handle that representation before asking the host numeric library to
    -- format anything.
    local decimal_integer = text:match("^([+-]?%d+)%.0+$")
    if decimal_integer then
        return decimal_integer
    end

    local number = tonumber(text)
    if number and number == math.floor(number) then
        -- Defold Editor's LuaJ floating-point string.format("%.0f") returns
        -- `101.0`, unlike PUC Lua's `101`. Avoid that host-specific formatter
        -- so Tiled id `101.0` matches generated instance suffix `_101`.
        local integer_text = tostring(math.floor(number)):gsub("%.0+$", "")
        if integer_text ~= "" then
            return integer_text
        end
    end
    return text
end

local function parse_xml_attrs(attr_text)
    local attrs = {}
    if type(attr_text) ~= "string" then return attrs end
    for name, _, value in attr_text:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[name] = value
    end
    return attrs
end

local function template_basename(path)
    local normalized_path = tostring(path or ""):gsub("\\", "/")
    normalized_path = normalized_path:gsub("[?#].*$", ""):gsub("%%20", " ")
    local filename = normalized_path:match("([^/]+)$") or normalized_path
    if filename:lower():sub(-3) == ".tx" then
        filename = filename:sub(1, -4)
    end
    return normalize_type(filename)
end

local function finding(code, message, fields)
    local result = fields or {}
    result.code = code
    result.message = message
    return result
end

local function add_error(report, code, message, fields)
    report.errors[#report.errors + 1] = finding(code, message, fields)
end

local function add_warning(report, code, message, fields)
    report.warnings[#report.warnings + 1] = finding(code, message, fields)
end

-- Collect visible objects from visible object layers named "templates".
-- Nested Tiled group layers are traversed recursively and inherit visibility.
function M.collect_template_objects(tiled_map)
    local collected = {}

    local function walk(layers, parent_visible, parent_path)
        if type(layers) ~= "table" then return end
        for _, layer in ipairs(layers) do
            if type(layer) == "table" then
                local layer_visible = parent_visible and is_visible(layer.visible)
                local layer_name = tostring(layer.name or "<unnamed>")
                local layer_path = parent_path == "" and layer_name
                    or (parent_path .. "/" .. layer_name)

                if layer.type == "group" then
                    walk(layer.layers, layer_visible, layer_path)
                elseif layer.type == "objectgroup"
                    and layer_visible
                    and normalize_type(layer.name) == "templates"
                    and type(layer.objects) == "table"
                then
                    for _, object in ipairs(layer.objects) do
                        if type(object) == "table" and is_visible(object.visible) then
                            collected[#collected + 1] = {
                                object = object,
                                layer_name = layer_name,
                                layer_path = layer_path,
                            }
                        end
                    end
                end
            end
        end
    end

    walk(type(tiled_map) == "table" and tiled_map.layers or nil, true, "")
    return collected
end

-- Extract top-level instance ids from Defold collection protobuf text. The
-- pattern intentionally accepts instances, embedded_instances, and
-- collection_instances while ignoring nested component/property ids.
function M.collect_collection_instance_ids(collection_text)
    local ids = {}
    local seen = {}
    local text = type(collection_text) == "string" and collection_text or ""
    for id in text:gmatch("[%w_]*instances%s*{%s*id%s*:%s*\"([^\"]+)\"") do
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    return ids
end

-- Return object-id -> normalized template basename for all template-backed
-- TMX objects. Attribute order and single/double quotes are both supported.
function M.parse_tmx_templates(tmx_text)
    local templates = {}
    if type(tmx_text) ~= "string" or tmx_text == "" then return templates end
    for attr_text in tmx_text:gmatch("<object%s+([^>]*)>") do
        local attrs = parse_xml_attrs(attr_text)
        local object_id = canonical_object_id(attrs.id)
        local basename = template_basename(attrs.template)
        if object_id and basename then
            templates[object_id] = {
                basename = basename,
                path = attrs.template,
            }
        end
    end
    return templates
end

local function infer_room_id(collection_text)
    if type(collection_text) ~= "string" then return nil end
    local collection_name = collection_text:match("^%s*name%s*:%s*\"([^\"]+)\"")
        or collection_text:match("[\r\n]%s*name%s*:%s*\"([^\"]+)\"")
    if not collection_name or collection_name == "" then return nil end
    return collection_name:gsub("_col$", "")
end

local function find_matching_instance(instance_ids, room_id, object_id)
    local prefix = tostring(room_id) .. "_"
    local suffix = "_" .. tostring(object_id)
    for _, instance_id in ipairs(instance_ids) do
        if instance_id:sub(1, #prefix) == prefix
            and instance_id:sub(-#suffix) == suffix
            and #instance_id > (#prefix + #suffix)
        then
            return instance_id
        end
    end
    return nil
end

local function resolve_for_audit(object, resolver, known_types, known_set, known_types_supplied)
    local resolved, source, resolver_error = nil, nil, nil
    if type(resolver) == "function" then
        local ok, value, value_source = pcall(resolver, object, known_types)
        if ok then
            resolved = normalize_type(value)
            source = value_source
        else
            source = "resolver_error"
            resolver_error = tostring(value)
        end
    else
        resolved = normalize_type(object and (object.type or object.class or object.className))
        source = resolved and "explicit" or "missing"
    end

    local reported_type = resolved
    local source_name = tostring(source or "")
    if source_name == "unknown_explicit" or source_name == "missing"
        or source_name == "resolver_error"
    then
        resolved = nil
    elseif resolved and known_types_supplied and not known_set[resolved] then
        resolved = nil
        if source_name == "" then source = "unknown" end
    end

    return resolved, source or "missing", resolver_error, reported_type
end

local function template_matches(template_type, resolved_type, aliases)
    if not template_type or not resolved_type then return false end
    if template_type == resolved_type then return true end
    return aliases[template_type] and aliases[template_type][resolved_type] == true
end

local function grapple_collision_valid(text)
    local doc = ResourceText.parse(text)
    for _, component in ipairs(ResourceText.all(doc.root, "embedded_components")) do
        if ResourceText.value(component.node, "type") == "collisionobject" then
            local collision = ResourceText.parse(ResourceText.value(component.node, "data") or "").root
            if ResourceText.value(collision, "group") == "grapple"
                and ResourceText.value(collision, "type") == "COLLISION_OBJECT_TYPE_STATIC" then
                for _, mask in ipairs(ResourceText.all(collision, "mask")) do
                    if mask.value == "grapple" then return true end
                end
            end
        end
    end
    return false
end

-- Share a single collection parse between painted strips and authored shapes.
local function collection_instance_map(collection_text)
    local parsed, collection = pcall(ResourceText.parse, collection_text)
    if not parsed then return nil, collection end
    local instances = {}
    for _, entry in ipairs(collection.root.entries) do
        if (entry.name == "instances" or entry.name == "embedded_instances") and entry.node then
            local id = ResourceText.value(entry.node, "id")
            if id then instances[id] = entry end
        end
    end
    return instances
end

local function instance_prototype_text(opts, instance)
    local prototype = ResourceText.value(instance.node, "prototype")
    if instance.name == "embedded_instances" then
        return ResourceText.value(instance.node, "data"), nil, prototype
    end
    if type(opts.read_resource) ~= "function" or not prototype then
        return nil, "no resource reader or prototype path", prototype
    end
    local read_ok, value, err = pcall(opts.read_resource, prototype)
    if read_ok then return value, err, prototype end
    return nil, value, prototype
end

local function audit_grapple_object(report, opts, instances, parse_error, room_id, audit_record)
    local id = audit_record.instance_id
    local fields = { room_id = room_id, object_id = audit_record.object_id,
        resolved_type = audit_record.resolved_type, instance_id = id }
    audit_record.grapple_collision = "invalid"
    if not instances then
        add_error(report, "invalid_grapple_collection", "room '" .. room_id .. "' grapple collection could not be parsed: " .. tostring(parse_error),
            fields)
        return
    end
    local instance = instances[id]
    local text, read_error, prototype
    if instance then
        text, read_error, prototype = instance_prototype_text(opts, instance)
    else
        read_error = "no gameobject instance data"
    end
    fields.prototype = prototype
    if type(text) ~= "string" then
        add_error(report, "missing_grapple_object_resource", string.format(
            "room '%s' %s object id=%s instance '%s' cannot read prototype '%s': %s",
            room_id, audit_record.resolved_type, audit_record.object_id, id,
            tostring(prototype or "<embedded>"), tostring(read_error or "resource missing")), fields)
        return
    end
    local parsed, valid = pcall(grapple_collision_valid, text)
    if not parsed or not valid then
        add_error(report, "invalid_grapple_object_collision", string.format(
            "room '%s' %s object id=%s instance '%s' prototype '%s' requires a static collisionobject with group 'grapple' and mask 'grapple'; run Prepare & Check",
            room_id, audit_record.resolved_type, audit_record.object_id, id,
            tostring(prototype or "<embedded>")), fields)
    else
        audit_record.grapple_collision = "ok"
    end
end

local function audit_grapple_strips(report, opts, tiled_map, instances, parse_error, room_id)
    local ok, runs = pcall(GrappleLayerBake.collect, tiled_map)
    if not ok then
        add_error(report, "invalid_grapple_layer", "room '" .. room_id .. "' grapple layer could not be audited: " .. tostring(runs),
            { room_id = room_id })
        return
    end
    if #runs == 0 then return end
    if not instances then
        add_error(report, "invalid_grapple_collection", "room '" .. room_id .. "' grapple collection could not be parsed: " .. tostring(parse_error),
            { room_id = room_id })
        return
    end
    for _, run in ipairs(runs) do
        local id = GrappleLayerBake.instance_id(run)
        local instance = instances[id]
        local record = { instance_id = id, row = run.row, col = run.col, x = run.x, y = run.y, width = run.w, height = run.h }
        local fields = { room_id = room_id, instance_id = id, row = run.row, col = run.col }
        if not instance then
            record.status = "missing"
            add_error(report, "missing_grapple_layer_instance", string.format(
                "room '%s' painted grapple strip '%s' has no baked collection instance; run Prepare & Check", room_id, id), fields)
        else
            local text, read_error, prototype = instance_prototype_text(opts, instance)
            record.prototype = prototype
            fields.prototype = record.prototype
            if type(text) ~= "string" or text == "" then
                record.status = "missing_resource"
                add_error(report, "missing_grapple_layer_resource", string.format(
                    "room '%s' grapple strip '%s' cannot read prototype '%s': %s", room_id, id,
                    tostring(record.prototype or "<embedded>"), tostring(read_error or "resource missing")), fields)
            else
                local valid, collision_ok = pcall(grapple_collision_valid, text)
                if not valid or not collision_ok then
                    record.status = "invalid_collision"
                    add_error(report, "invalid_grapple_layer_collision", string.format(
                        "room '%s' grapple strip '%s' prototype '%s' requires a static collisionobject with group 'grapple' and mask 'grapple'%s",
                        room_id, id, tostring(record.prototype or "<embedded>"), valid and "" or (": " .. tostring(collision_ok))), fields)
                else record.status = "baked" end
            end
        end
        report.grapple_strips[#report.grapple_strips + 1] = record
    end
end

-- Audit one generated room.
--
-- Required options:
--   tiled_map              loaded Tiled Lua export table
--   collection_text        generated .collection protobuf text
--   known_types            resolver's registered type set/list
--   resolve_object_type    function(object, known_types) -> type, source
--   build_time_skip_types  set/list used for skip_spawn_<type>
--
-- Optional options:
--   room_id                inferred from collection name "<room>_col" if absent
--   tmx_text               sibling TMX text for template/type comparison
--   template_aliases       extra template basename -> resolved-type mappings
--   read_resource          function(resource_path) -> prototype text for grapple collision checks
--
-- Returns a report with structured errors/warnings and one audit record per
-- visible templates-layer object.
function M.audit_room(options)
    local opts = type(options) == "table" and options or {}
    local tiled_map = opts.tiled_map or opts.map
    local collection_text = opts.collection_text or ""
    local room_id = trim(opts.room_id)
    if room_id == "" then
        room_id = trim(type(tiled_map) == "table" and tiled_map.room_id or nil)
    end
    if room_id == "" then room_id = trim(infer_room_id(collection_text)) end

    local report = {
        ok = true,
        room_id = room_id ~= "" and room_id or nil,
        errors = {},
        warnings = {},
        objects = {},
        grapple_strips = {},
        instance_ids = M.collect_collection_instance_ids(collection_text),
    }

    if type(tiled_map) ~= "table" then
        add_error(report, "invalid_tiled_map",
            "bake audit requires a loaded Tiled map table",
            { room_id = report.room_id })
        report.ok = false
        return report
    end
    if room_id == "" then
        add_error(report, "missing_room_id",
            "bake audit could not determine the room id needed to match collection instances")
        report.ok = false
        return report
    end

    local known_types_supplied = type(opts.known_types) == "table"
    local known_set = normalize_set(opts.known_types)
    local skip_values = opts.build_time_skip_types or opts.skip_types
    local skip_set = normalize_set(skip_values)
    local aliases = copy_aliases(opts.template_aliases or opts.aliases)
    local tmx_templates = M.parse_tmx_templates(opts.tmx_text)
    local template_entries = M.collect_template_objects(tiled_map)
    local instances, parse_error = collection_instance_map(collection_text)

    for _, entry in ipairs(template_entries) do
        local object = entry.object
        local object_id = canonical_object_id(object.id)
        local resolved_type, type_source, resolver_error, reported_type = resolve_for_audit(
            object,
            opts.resolve_object_type,
            opts.known_types,
            known_set,
            known_types_supplied
        )
        if resolved_type == "gate" then
            local props = PropertyFlattener.flatten(object.properties)
            local warning = RetiredTypes.required_ability_warning(object, room_id, props.required_ability)
            if warning then add_warning(report, "retired_required_ability", warning, { room_id = room_id, object_id = object_id }) end
        end
        local instance_id = object_id
            and find_matching_instance(report.instance_ids, room_id, object_id)
            or nil
        local template_record = object_id and tmx_templates[object_id] or nil
        local audit_record = {
            object_id = object_id,
            object_name = object.name,
            layer_name = entry.layer_name,
            layer_path = entry.layer_path,
            resolved_type = resolved_type,
            reported_type = reported_type,
            type_source = type_source,
            resolver_error = resolver_error,
            instance_id = instance_id,
            template_basename = template_record and template_record.basename or nil,
            template_path = template_record and template_record.path or nil,
        }

        if not object_id then
            audit_record.status = "invalid_object_id"
            add_error(report, "missing_object_id", string.format(
                "room '%s' has a visible templates-layer object without a Tiled object id",
                room_id), {
                    room_id = room_id,
                    object_name = object.name,
                    layer_path = entry.layer_path,
                })
        elseif RetiredTypes.is_object_type(reported_type) then
            audit_record.status = "retired"
            add_warning(report, "retired_object_type", RetiredTypes.warning(object, room_id), {
                room_id = room_id, object_id = object_id,
                reported_type = reported_type, layer_path = entry.layer_path,
            })
        elseif instance_id then
            audit_record.status = "baked"
        elseif not resolved_type then
            audit_record.status = "missing_unresolvable"
            add_error(report, "missing_unresolvable_instance", string.format(
                "room '%s' templates object id=%s ('%s') has no baked collection instance and no resolvable registered type; it would be absent at runtime",
                room_id,
                object_id,
                tostring(object.name or "<unnamed>")), {
                    room_id = room_id,
                    object_id = object_id,
                    object_name = object.name,
                    layer_path = entry.layer_path,
                    type_source = type_source,
                    reported_type = reported_type,
                    resolver_error = resolver_error,
                })
        elseif skip_set[resolved_type] then
            audit_record.status = "missing_skipped"
            add_error(report, "missing_skipped_instance", string.format(
                "room '%s' templates object id=%s ('%s') resolved as '%s' but has no baked collection instance; runtime spawning is disabled by skip_spawn_%s",
                room_id,
                object_id,
                tostring(object.name or "<unnamed>"),
                resolved_type,
                resolved_type), {
                    room_id = room_id,
                    object_id = object_id,
                    object_name = object.name,
                    layer_path = entry.layer_path,
                    resolved_type = resolved_type,
                    type_source = type_source,
                    runtime_skipped = true,
                })
        else
            audit_record.status = "missing_instance"
            add_error(report, "missing_baked_instance", string.format(
                "room '%s' templates object id=%s ('%s') resolved as '%s' but has no baked collection instance",
                room_id, object_id, tostring(object.name or "<unnamed>"), resolved_type), {
                    room_id = room_id, object_id = object_id, object_name = object.name,
                    layer_path = entry.layer_path, resolved_type = resolved_type,
                    type_source = type_source,
                })
        end

        if instance_id and (resolved_type == "grapple_box" or resolved_type == "grapple_slope"
            or resolved_type == "grapple_surface")
        then
            audit_grapple_object(report, opts, instances, parse_error, room_id, audit_record)
        end

        if template_record and resolved_type
            and not template_matches(template_record.basename, resolved_type, aliases)
        then
            add_warning(report, "template_type_mismatch", string.format(
                "room '%s' templates object id=%s uses template '%s.tx' but resolved as '%s'",
                room_id,
                tostring(object_id),
                template_record.basename,
                resolved_type), {
                    room_id = room_id,
                    object_id = object_id,
                    object_name = object.name,
                    layer_path = entry.layer_path,
                    template_basename = template_record.basename,
                    template_path = template_record.path,
                    resolved_type = resolved_type,
                    type_source = type_source,
                })
        end

        report.objects[#report.objects + 1] = audit_record
    end

    audit_grapple_strips(report, opts, tiled_map, instances, parse_error, room_id)
    report.ok = #report.errors == 0
    return report
end

M.audit = M.audit_room

return M
