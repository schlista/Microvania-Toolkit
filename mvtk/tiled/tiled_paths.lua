-- Read authored paths from the same room map used for baked object properties.
local AuthoredObjectProps = require "mvtk.tiled.authored_object_props"

local M = {}

local function find_path(layers, name)
    for _, layer in ipairs(layers or {}) do
        if layer.type == "group" then
            local object = find_path(layer.layers, name)
            if object then return object end
        elseif layer.type == "objectgroup" then
            for _, object in ipairs(layer.objects or {}) do
                if object.name == name and (object.polyline or object.polygon) then
                    return object
                end
            end
        end
    end
end

function M.get_polyline(room_id, name)
    if not name or name == "" then return nil end
    local map = AuthoredObjectProps.get_map(room_id)
    if not map then return nil end
    local object = find_path(map.layers, name)
    if not object then return nil end
    -- Convert only the origin. Consumers subtract the untouched Tiled point Y
    -- offsets when constructing their Defold-space world waypoints.
    local map_height_px = (map.height or 0) * (map.tileheight or 0)
    return {
        x = object.x,
        y = map_height_px - (object.y or 0),
        polyline = object.polyline,
        polygon = object.polygon,
        name = object.name,
    }
end

return M
