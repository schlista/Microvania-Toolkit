-- Pure Route C resolver for shared prefabs whose only per-instance change is
-- visual ownership. Filesystem reads/writes remain in the editor host.

local VisualOwnership = require "mvtk.tiled.visual_ownership"
local ProtoUtils = require "mvtk.editor.proto_utils"

local M = {}

local function token(value, fallback)
    local result = tostring(value or fallback or "object"):gsub("[^%w_]", "_")
    result = result:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return result ~= "" and result or fallback or "object"
end

function M.generated_resource(rid, object_type, object_id)
    return string.format(
        "/developer/rooms/generated/%s_%s_%s.go",
        token(rid, "room"),
        token(VisualOwnership.normalize_type(object_type), "object"),
        token(object_id, "unknown")
    )
end

-- Returns resource, generated_text, removed_count. generated_text is nil when
-- the shared source should remain in use or the source has no removable sprite.
function M.resolve(rid, object, object_type, source_resource, source_text)
    if VisualOwnership.uses_defold_sprite(object, object_type) then
        return source_resource, nil, 0
    end
    local stripped, count = ProtoUtils.strip_sprite_components(source_text)
    if count == 0 then
        return source_resource, nil, 0
    end
    return M.generated_resource(rid, object_type, object and object.id), stripped, count
end

return M
