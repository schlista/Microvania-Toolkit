local TP = require "mvtk.core.tiled_props"
local Util = require "mvtk.core.util"
local AuthoredObjectProps = require "mvtk.tiled.authored_object_props"
-- Keep the generated room registry statically visible to Defold's dependency
-- scanner; release hashes can only be reversed by comparing against these ids.
local RoomsConfig = require "developer.config.rooms_config"

local M = {}

function M.plain(value, default)
    local resolved = TP.normalize_hash_string(value)
    if resolved == nil or resolved == "" then
        return default or ""
    end
    return resolved
end

function M.optional_plain(value)
    local resolved = M.plain(value, "")
    if string.lower(resolved) == "none" then
        return ""
    end
    return resolved
end

function M.bool(value, default)
    return TP.to_bool(value, default)
end

function M.number(value, default)
    local resolved = tonumber(value)
    if resolved == nil then
        return default
    end
    return resolved
end

function M.room_id(self)
    local raw = self and self.room_id
    local resolved = M.plain(raw, "")
    if resolved ~= "" then
        return resolved
    end

    -- A serialized hash may have no reverse name in release builds. Compare
    -- it to hashes of configured room ids instead; equality remains reliable.
    for room_path in pairs(RoomsConfig.factories or {}) do
        local candidate = tostring(room_path):gsub("\\", "/"):match("([^/]+)$")
        if candidate and candidate ~= "" then
            local ok_hash, candidate_hash = pcall(hash, candidate)
            if ok_hash and candidate_hash == raw then
                return candidate
            end
        end
    end
    return ""
end

function M.instance_tail()
    local ok_id, value = pcall(go.get_id)
    if not ok_id or value == nil then
        return ""
    end
    local id = Util.go_id_text(value)
    if not id then return "" end
    return id:match("([^/]+)$") or id
end

function M.registration_id(self, fallback)
    local resolved = M.plain(self and self.registration_id, "")
    if resolved ~= "" then
        return resolved
    end
    resolved = M.instance_tail()
    if resolved ~= "" then
        return resolved
    end
    return fallback or ""
end

--- Return the exact properties from the exported Tiled object represented by
--- a baked proxy. Free-form strings cannot be recovered reliably from Defold
--- hash properties in release builds, so generated proxies carry the numeric
--- Tiled object id and use it to read the exported room Lua directly.
function M.authored_object(self, object_kind)
    local room_id = M.room_id(self)
    local object_id = math.floor(M.number(self and self.object_id, 0) or 0)

    local tail = M.instance_tail()
    if tail ~= "" and type(object_kind) == "string" and object_kind ~= "" then
        local escaped_kind = object_kind:gsub("([^%w])", "%%%1")
        local inferred_room, inferred_id = tail:match("^(.*)_" .. escaped_kind .. "_(%d+)$")
        if room_id == "" and inferred_room and inferred_room ~= "" then
            room_id = inferred_room
        end
        if object_id <= 0 and inferred_id then
            object_id = tonumber(inferred_id) or 0
        end
    end

    if room_id == "" or object_id <= 0 then
        return nil, nil, room_id, object_id
    end

    local properties, object = AuthoredObjectProps.get_properties(room_id, object_id)
    return properties, object, room_id, object_id
end

--- Overlay exact Tiled values onto values decoded from GO properties.
--- `schema` contains hash_fields, optional_hash_fields, number_fields, and
--- bool_fields arrays. Only fields present in the authored object are changed.
function M.overlay_authored(self, target, schema)
    target = target or {}
    schema = schema or {}

    local authored, object, room_id, object_id = M.authored_object(self, schema.object_kind)
    target.room_id = room_id
    target.object_id = object_id
    if type(authored) ~= "table" then
        return target, object, false
    end

    local optional = {}
    for _, field in ipairs(schema.optional_hash_fields or {}) do
        optional[field] = true
    end

    for _, field in ipairs(schema.hash_fields or {}) do
        if authored[field] ~= nil then
            if optional[field] then
                target[field] = M.optional_plain(authored[field])
            else
                target[field] = M.plain(authored[field], "")
            end
        end
    end
    for _, field in ipairs(schema.number_fields or {}) do
        if authored[field] ~= nil then
            target[field] = M.number(authored[field], target[field])
        end
    end
    for _, field in ipairs(schema.bool_fields or {}) do
        if authored[field] ~= nil then
            target[field] = M.bool(authored[field], target[field])
        end
    end

    return target, object, true
end

function M.world_position()
    return go.get_world_position()
end

function M.post_to_main(message_name, payload)
    local ok, err = pcall(msg.post, "main:/main_go#script", hash(message_name), payload)
    if not ok then
        print(string.format("[TILED_PROXY] Failed to post %s: %s", tostring(message_name), tostring(err)))
    end
    return ok, err
end

return M
