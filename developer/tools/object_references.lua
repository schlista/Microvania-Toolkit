-- Native Tiled object links are map-local numeric IDs. Resolve on a copy so
-- the source retains Tiled's rename/duplicate tracking and string IDs still work.
local Properties = require "mvtk.tiled.property_flattener"
local Objects = require "hooks.core.tiled_objects"
local Proto = require "mvtk.editor.proto_emit"
local M = {}

M.fields = {target_ref = "target_id", boss_ref = "boss_id", arena_ref = "arena_id"}
M.targets = {
    target_id = {timed_door = "door_id", hazard = "hazard_id", elevator = "elevator_id", teleporter = "teleporter_id"},
    boss_id = {boss = "boss_id"}, arena_id = {boss_arena = "arena_id"},
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for k,v in pairs(value) do out[k] = copy(v) end; return out
end

local function walk(layers, fn, path, visible)
    for _,layer in ipairs(layers or {}) do
        local name = path and path .. "/" .. (layer.name or "?") or layer.name or "?"
        local shown = visible ~= false and layer.visible ~= false
        for _,object in ipairs(layer.objects or {}) do fn(object, name, shown and object.visible ~= false) end
        walk(layer.layers, fn, name, shown)
    end
end
M.walk = walk

local function present(v) return v ~= nil and tostring(v) ~= "" end

function M.normalize(map, room)
    local out, diagnostics, records, by_id = copy(map), {}, {}, {}
    local file = "developer/assets/tiled/maps/" .. room .. ".lua"
    local function report(r, code, field, message)
        diagnostics[#diagnostics+1] = {severity="error", code=code, file=file, room=room,
            layer=r.layer, object_id=r.object.id, object_type=r.kind, property=field,
            message=message, fix="In Tiled select this object by ID and choose a visible object in this map."}
    end
    walk(out.layers, function(object, layer, visible)
        object.properties = Properties.flatten(object.properties or {})
        local r = {object=object, layer=layer, visible=visible,
            kind=Objects.resolve_object_type(object) or object.type or "unknown"}
        records[#records+1] = r
        local id = tonumber(object.id)
        if id then
            if by_id[id] then report(r,"duplicate_object_id",nil,"Tiled object ID is repeated in this map.")
            else by_id[id] = r end
        end
    end)
    for _,r in ipairs(records) do
        if r.visible then
            for alias, field in pairs(M.fields) do
                local p = r.object.properties
                local value, source = p[alias], alias
                -- Tiled exports an unset object property as either 0 or {id=0}.
                -- Both leave the authored string ID (or optional blank) in use.
                if value == nil or value == 0 or (type(value) == "table" and value.id == 0) then
                    p[alias] = nil
                    value, source = p[field], field
                    if type(value) ~= "number" then value = nil end
                end
                if value ~= nil then
                    local id = tonumber(type(value)=="table" and value.id or value)
                    local target = id and by_id[id]
                    if not target or not target.visible then
                        report(r,"dangling_object_reference",source,"The referenced object is missing or hidden (ID " .. tostring(id or value) .. ").")
                    else
                        local target_field = M.targets[field][target.kind]
                        if field == "target_id" then
                            if (r.kind == "teleporter") ~= (target.kind == "teleporter") then target_field = nil end
                        end
                        if not target_field then
                            report(r,"wrong_object_reference_type",source,"The referenced " .. target.kind .. " cannot supply " .. field .. ".")
                        else
                            local tp = target.object.properties
                            local key = tp[target_field]
                            if not present(key) and target_field == "boss_id" and present(tp.boss_tag) then
                                key=tp.boss_tag
                                tp[target_field]=key
                            end
                            if not present(key) then
                                -- Explicit IDs avoid the different blank/name fallbacks
                                -- of baked scripts and unloaded-room registries.
                                key = Proto.generated_object_id(room, target.kind, target.object.id)
                                tp[target_field] = key
                            end
                            p[field] = tostring(key)
                            p[alias] = nil
                        end
                    end
                end
            end
        end
    end
    return out, diagnostics
end

return M
