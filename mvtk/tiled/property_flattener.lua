-- mvtk/tiled/property_flattener.lua
--
-- Canonicalize Tiled custom properties without mutating the exported table.
-- Supports the keyed shape emitted by the bundled exporter, native arrays of
-- property records, scalar wrappers, and one level of class-valued groups.

local M = {}

-- This registry is required for resolving collisions between legacy flat
-- properties and the default values repeated inside Tiled class groups. Keep
-- the dependency literal so Defold's build scanner bundles it; a dynamic
-- require here can disappear from release builds and lets grouped defaults
-- erase explicit authored values (including boss phase attack lists).
local DefaultRegistry = require "mvtk.tiled.property_groups"
local registry = DefaultRegistry

local RECORD_METADATA_KEYS = {
    inherited = true,
    Inherited = true,
    name = true,
    Name = true,
    propertytype = true,
    propertyType = true,
    type = true,
    Type = true,
    value = true,
    Value = true,
}

local function copy_value(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do
        copy[copy_value(key, seen)] = copy_value(child, seen)
    end
    return copy
end

local function values_equal(a, b, seen)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[a] == b then
        return true
    end
    seen[a] = b
    for key, value in pairs(a) do
        if not values_equal(value, b[key], seen) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
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

local function to_optional_bool(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "boolean" then return value end
    if type(value) == "number" then
        if value == 0 then return false end
        if value == 1 then return true end
        return nil
    end
    local token = tostring(value):lower()
    if token == "false" or token == "0" then return false end
    if token == "true" or token == "1" then return true end
    return nil
end

local function record_name(record)
    if type(record) ~= "table" then return nil end
    local name = rawget(record, "name")
    if name == nil then name = rawget(record, "Name") end
    if name == nil or tostring(name) == "" then return nil end
    return tostring(name)
end

local function record_value(record)
    if type(record) ~= "table" then return nil, false end
    if rawget(record, "value") ~= nil then
        return unwrap(rawget(record, "value")), true
    end
    if rawget(record, "Value") ~= nil then
        return unwrap(rawget(record, "Value")), true
    end
    return nil, false
end

local function is_single_record(container)
    if type(container) ~= "table" or not record_name(container) then
        return false
    end
    local _, has_value = record_value(container)
    if not has_value then return false end
    for key in pairs(container) do
        if type(key) == "number" or not RECORD_METADATA_KEYS[key] then
            return false
        end
    end
    return true
end

-- Return name -> entry while preserving the property-array precedence used by
-- the editor resolver: keyed fields win; otherwise the first explicit
-- inherited=false record wins, and a non-inherited record can replace an
-- inherited template default.
local function collect_named(container)
    local found = {}
    if type(container) ~= "table" then return found end

    if is_single_record(container) then
        local value = record_value(container)
        local inherited_value = rawget(container, "inherited")
        if inherited_value == nil then inherited_value = rawget(container, "Inherited") end
        found[record_name(container)] = {
            value = value,
            inherited = to_optional_bool(inherited_value),
            source = "record",
        }
        return found
    end

    for key, value in pairs(container) do
        if type(key) == "string" then
            found[key] = {
                value = unwrap(value),
                inherited = nil,
                source = "keyed",
                locked = true,
            }
        end
    end

    for _, record in ipairs(container) do
        local name = record_name(record)
        local value, has_value = record_value(record)
        if name and has_value then
            local inherited = to_optional_bool(rawget(record, "inherited"))
            if inherited == nil then
                inherited = to_optional_bool(rawget(record, "Inherited"))
            end
            local current = found[name]
            if not current then
                found[name] = {
                    value = value,
                    inherited = inherited,
                    source = "record",
                    locked = inherited == false,
                }
            elseif not current.locked and inherited == false then
                found[name] = {
                    value = value,
                    inherited = inherited,
                    source = "record",
                    locked = true,
                }
            elseif not current.locked and current.inherited == true and inherited ~= true then
                found[name] = {
                    value = value,
                    inherited = inherited,
                    source = "record",
                    locked = inherited == false,
                }
            end
        end
    end

    return found
end

local function normalized_registry_groups(candidate)
    if type(candidate) ~= "table" then return {} end
    if type(candidate.groups) == "table" then return candidate.groups end
    if type(candidate.GROUPS) == "table" then return candidate.GROUPS end
    if type(candidate.property_groups) == "table" then return candidate.property_groups end
    return candidate
end

local function load_registry()
    return registry
end

-- Override the generated registry. Passing nil deliberately disables it for
-- the current Lua state; reset_registry() restores the bundled default.
function M.set_registry(value)
    registry = type(value) == "table" and value or nil
end

function M.reset_registry()
    registry = DefaultRegistry
end

function M.get_registry()
    return load_registry()
end

local function group_spec(groups, group_name)
    groups = normalized_registry_groups(groups)
    return groups[group_name]
end

local function member_spec(spec, member_name)
    if type(spec) ~= "table" then return nil, false end
    local members = spec.members or spec.fields or spec.properties or spec
    if type(members) ~= "table" then return nil, false end

    local direct = members[member_name]
    if direct ~= nil then return direct, true end
    for _, member in ipairs(members) do
        if member == member_name then return true, true end
        if type(member) == "table" then
            local name = member.name or member.Name
            if name == member_name then return member, true end
        end
    end
    return nil, false
end

local function member_defaults(spec, member_name)
    local member, exists = member_spec(spec, member_name)
    if not exists or type(member) ~= "table" then return {}, false end
    local defaults = {}
    if rawget(member, "default") ~= nil then
        defaults[#defaults + 1] = unwrap(rawget(member, "default"))
    elseif rawget(member, "default_value") ~= nil then
        defaults[#defaults + 1] = unwrap(rawget(member, "default_value"))
    elseif rawget(member, "defaultValue") ~= nil then
        defaults[#defaults + 1] = unwrap(rawget(member, "defaultValue"))
    end
    if type(rawget(member, "defaults")) == "table" then
        for _, value in ipairs(rawget(member, "defaults")) do
            defaults[#defaults + 1] = unwrap(value)
        end
    end
    return defaults, #defaults > 0
end

local function looks_like_group(value)
    value = unwrap(value)
    if type(value) ~= "table" then return false end

    -- Native Tiled Lua encodes object references as { id = N }. This is a
    -- scalar property, not a class group; flattening it discards its name
    -- (for example owner_ref) and detaches artwork from its gameplay owner.
    if type(rawget(value, "id")) == "number" and next(value, "id") == nil
        and next(value) == "id" then return false end

    local count = 0
    local array_count = 0
    for _, record in ipairs(value) do
        array_count = array_count + 1
        local _, has_value = record_value(record)
        if not record_name(record) or not has_value then
            return false
        end
    end
    if array_count > 0 then return true end

    for key in pairs(value) do
        if type(key) == "string" and not RECORD_METADATA_KEYS[key] then
            count = count + 1
        end
    end
    return count > 0
end

local function sorted_names(entries)
    local names = {}
    for name in pairs(entries) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function choose_collision(context, options)
    if type(options.collision_resolver) == "function" then
        local value, resolution, reason = options.collision_resolver(context)
        if resolution == "flat" or resolution == "existing" then
            return context.flat_value, "flat", reason or "custom"
        end
        if resolution == "group" or resolution == "grouped" or resolution == "nested" then
            return context.grouped_value, "grouped", reason or "custom"
        end
        if value ~= nil then
            return value, resolution or "custom", reason or "custom"
        end
    end

    if context.existing_source.kind == "flat" and context.has_group_default
        and context.grouped_inherited ~= false
    then
        for _, default in ipairs(context.group_defaults or {}) do
            if values_equal(context.grouped_value, default) then
                return context.flat_value, "flat", "group_default"
            end
        end
    end
    return context.grouped_value, "grouped", "group_override"
end

-- Flatten one level of class-valued properties.
--
-- Options:
--   registry             registry table for this call (does not change global)
--   load_registry=false  skip the optional generated registry
--   groups               additional/limiting group descriptions
--   detect_groups=false  only flatten groups named by `groups` or registry
--   ignore_grouped_value function(context) -> true to omit an inherited value
--   collision_resolver   function(context) -> value, resolution, reason
--
-- Returns: flattened_properties, collision_diagnostics
function M.flatten(properties, options)
    options = options or {}
    local entries = collect_named(properties)
    local generated_registry = options.registry
    if generated_registry == nil and options.load_registry ~= false then
        generated_registry = load_registry()
    end
    local registered = normalized_registry_groups(generated_registry)
    local requested = normalized_registry_groups(options.groups)
    local detect_groups = options.detect_groups ~= false

    local groups = {}
    local flattened = {}
    local present = {}
    local sources = {}
    local diagnostics = {}

    for _, name in ipairs(sorted_names(entries)) do
        local entry = entries[name]
        local requested_spec = requested[name]
        local registered_spec = registered[name]
        local spec = requested_spec or registered_spec
        -- A group name may also be a perfectly valid scalar leaf elsewhere
        -- (for example `movement` or map-level `music`). Registry membership
        -- is therefore a hint, never enough by itself to consume the value.
        local is_table_value = type(unwrap(entry.value)) == "table"
        if (is_table_value and spec ~= nil) or (detect_groups and looks_like_group(entry.value)) then
            groups[#groups + 1] = {
                name = name,
                value = entry.value,
                spec = spec or group_spec(registered, name),
            }
        else
            flattened[name] = copy_value(entry.value)
            present[name] = true
            sources[name] = { kind = "flat", name = name }
        end
    end

    table.sort(groups, function(a, b) return a.name < b.name end)
    for _, group in ipairs(groups) do
        local members = collect_named(unwrap(group.value))
        for _, field in ipairs(sorted_names(members)) do
            local grouped_value = members[field].value
            local ignore_grouped = false
            if type(options.ignore_grouped_value) == "function" then
                ignore_grouped = options.ignore_grouped_value({
                    field = field,
                    property = field,
                    group = group.name,
                    grouped_value = grouped_value,
                    nested_value = grouped_value,
                    has_existing = present[field] == true,
                    existing_value = flattened[field],
                    existing_source = sources[field],
                }) == true
            end
            if ignore_grouped then
                if present[field] then
                    diagnostics[#diagnostics + 1] = {
                        kind = sources[field].kind == "group" and "group_group" or "flat_group",
                        field = field,
                        property = field,
                        group = group.name,
                        existing_group = sources[field].group,
                        flat_value = copy_value(flattened[field]),
                        grouped_value = copy_value(grouped_value),
                        resolution = "flat",
                        reason = "ignored_group_value",
                        values_equal = values_equal(flattened[field], grouped_value),
                    }
                end
            elseif not present[field] then
                flattened[field] = copy_value(grouped_value)
                present[field] = true
                sources[field] = { kind = "group", group = group.name, name = field }
            else
                local defaults, has_default = member_defaults(group.spec, field)
                if not has_default then
                    local registry_spec = group_spec(registered, group.name)
                    defaults, has_default = member_defaults(registry_spec, field)
                end
                local existing_value = flattened[field]
                local context = {
                    field = field,
                    property = field,
                    group = group.name,
                    flat_value = existing_value,
                    existing_value = existing_value,
                    grouped_value = grouped_value,
                    nested_value = grouped_value,
                    grouped_inherited = members[field].inherited,
                    existing_source = sources[field],
                    group_default = defaults[1],
                    group_defaults = defaults,
                    has_group_default = has_default,
                }
                local chosen, resolution, reason = choose_collision(context, options)
                flattened[field] = copy_value(chosen)
                if resolution ~= "flat" and resolution ~= "existing" then
                    sources[field] = { kind = "group", group = group.name, name = field }
                end
                diagnostics[#diagnostics + 1] = {
                    kind = context.existing_source.kind == "group" and "group_group" or "flat_group",
                    field = field,
                    property = field,
                    group = group.name,
                    existing_group = context.existing_source.group,
                    flat_value = copy_value(existing_value),
                    grouped_value = copy_value(grouped_value),
                    resolution = resolution,
                    reason = reason,
                    values_equal = values_equal(existing_value, grouped_value),
                }
            end
        end
    end

    return flattened, diagnostics
end

function M.get(properties, field, options)
    if field == nil then return nil end
    local flattened, diagnostics = M.flatten(properties, options)
    return flattened[field], diagnostics
end

M.unwrap = unwrap

return M
