-- Authored Grapple Box/Slope shapes become editable static room instances, never runtime spawns.
local TileCollision = require "mvtk.tiled.tile_collision"

local M = {}

-- Must equal GRAPPLE_GROUP in mvtk/player/player_state.lua. Keep the self-mask
-- so hook raycasts see these tags; they add no player collision.
local GRAPPLE_GROUP = "grapple"
local GENERATED_RESOURCE_DIR = "/developer/rooms/generated/"
local RECTANGLE_FALLBACK = "no polygon; baking its rectangle. Re-drag the Grapple Slope template."

function M.hulls(obj, obj_type, map_height)
    local width = tonumber(obj.width) or 0
    local height = tonumber(obj.height) or 0
    if obj_type == "grapple_box" then
        if width <= 0 or height <= 0 then
            return nil, "empty_rect"
        end
    elseif obj_type == "grapple_slope" then
        if type(obj.polygon) == "table" and #obj.polygon >= 3 then
            local hulls, note = TileCollision.object_polygon_to_defold_points(
                obj.polygon, obj.x, obj.y, map_height, obj.rotation)
            return hulls, note or "no_shape"
        end
        if width <= 0 or height <= 0 then
            return nil, "no_shape"
        end
    else
        return nil, "unsupported_type"
    end

    local points = TileCollision.object_rect_to_defold_points(
        obj.x, obj.y, width, height, map_height, obj.rotation)
    if not points then
        return nil, "no_shape"
    end
    return { points }, obj_type == "grapple_slope" and RECTANGLE_FALLBACK or nil
end

function M.layout(hulls)
    local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
    for _, points in ipairs(hulls) do
        for _, point in ipairs(points) do
            min_x, min_y = math.min(min_x, point.x), math.min(min_y, point.y)
            max_x, max_y = math.max(max_x, point.x), math.max(max_y, point.y)
        end
    end
    local cx, cy = (min_x + max_x) / 2, (min_y + max_y) / 2
    local local_hulls = {}
    for i, points in ipairs(hulls) do
        local local_points = {}
        for j, point in ipairs(points) do
            local_points[j] = { x = point.x - cx, y = point.y - cy }
        end
        local_hulls[i] = local_points
    end
    return cx, cy, local_hulls
end

-- LuaJ ignores floating-point format precision; match tilesource.lua's
-- integer formatting and retain other coordinates with tostring.
local function fmt_float(n)
    if n == math.floor(n) then
        return string.format("%d.0", n)
    end
    return tostring(n)
end

function M.shape_text(points)
    local lines = { "shape_type: TYPE_HULL" }
    for _, point in ipairs(points) do
        lines[#lines + 1] = "data: " .. fmt_float(point.x)
        lines[#lines + 1] = "data: " .. fmt_float(point.y)
        lines[#lines + 1] = "data: 0.0"
    end
    return table.concat(lines, "\n") .. "\n"
end

function M.go_text(shape_resources)
    local lines = {}
    for i, resource in ipairs(shape_resources) do
        lines[#lines + 1] = "embedded_components {"
        lines[#lines + 1] = string.format('  id: "co_%d"', i)
        lines[#lines + 1] = '  type: "collisionobject"'
        lines[#lines + 1] = string.format('  data: "collision_shape: \\"%s\\"\\n"', resource)
        lines[#lines + 1] = '  "type: COLLISION_OBJECT_TYPE_STATIC\\n"'
        lines[#lines + 1] = '  "mass: 0.0\\n"'
        lines[#lines + 1] = '  "friction: 0.0\\n"'
        lines[#lines + 1] = '  "restitution: 0.0\\n"'
        lines[#lines + 1] = '  "group: \\"' .. GRAPPLE_GROUP .. '\\"\\n"'
        lines[#lines + 1] = '  "mask: \\"' .. GRAPPLE_GROUP .. '\\"\\n"'
        lines[#lines + 1] = '  ""'
        lines[#lines + 1] = "}"
    end
    return table.concat(lines, "\n") .. "\n"
end

function M.append(context, rows, rid, obj, obj_type, obj_id, map_height)
    local hulls, note = M.hulls(obj, obj_type, map_height)
    local tiled_id = math.floor(tonumber(obj.id) or 0)
    if not hulls or #hulls == 0 then
        context.info(string.format(
            "[CREATE ROOMS][WARNING] map '%s': %s object id=%d skipped: %s",
            tostring(rid), tostring(obj_type), tiled_id, note or "no_shape"))
        return false
    end
    if note == "bbox" or note == RECTANGLE_FALLBACK then
        context.info(string.format(
            "[CREATE ROOMS][WARNING] map '%s': %s object id=%d: %s",
            tostring(rid), tostring(obj_type), tiled_id,
            note == "bbox" and "polygon could not be decomposed; baking its bounding box." or note))
    end

    local cx, cy, local_hulls = M.layout(hulls)
    local resources = {}
    for i, points in ipairs(local_hulls) do
        local name = obj_id .. (#local_hulls > 1 and string.format("_%d", i) or "") .. ".convexshape"
        context.write_if_changed(context.join(context.PATH.generated_go, name), M.shape_text(points))
        resources[i] = GENERATED_RESOURCE_DIR .. name
    end
    context.write_if_changed(context.join(context.PATH.generated_go, obj_id .. ".go"), M.go_text(resources))
    context.add_prefab_instance(rows, obj_id, GENERATED_RESOURCE_DIR .. obj_id .. ".go", cx, cy)
    context.info(string.format("[CREATE ROOMS] room %s: %s id=%d -> %d hull(s)",
        tostring(rid), tostring(obj_type), tiled_id, #local_hulls))
    return true
end

return M
