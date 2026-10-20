-- mvtk/core/surface_classifier.lua
-- Shared helpers for classifying collision hits as ground, walls, or ceilings.

local M = {}

local DEFAULT_MAX_WALKABLE_SLOPE = 50

local GROUP_SOLID = hash("solid")
-- Legacy terrain groups are kept for layer-name lookup and backward-compatible
-- collision classification, but runtime raycasts must not query them now that
-- terrain collision has been consolidated onto the "solid" group.
local GROUP_GROUND = hash("ground")
local GROUP_WORLD = hash("world")
local GROUP_WALL = hash("wall")
local GROUP_CEILING = hash("ceiling")
local GROUP_PLATFORM = hash("platform")
local GROUP_BOUNDS = hash("bounds")
-- Every group named in a raycast claims one of the collision world's 16 group
-- slots, exactly like a collider's group or mask (Defold 1.14 script_physics.cpp
-- RayCast -> CompCollisionGetGroupBitIndex -> GetGroupBitIndex(readonly=false)).
-- No collider uses "bounds" (it is a Tiled layer name only), so querying it found
-- nothing yet took the 17th slot and broke grapple/pushable collision.
local ACTIVE_RAYCAST_GROUPS = { GROUP_SOLID, GROUP_WORLD, GROUP_PLATFORM }

M.KINDS = {
    UNKNOWN = "unknown",
    GROUND = "ground",
    WALL = "wall",
    CEILING = "ceiling",
}

M.GROUPS = {
    SOLID = GROUP_SOLID,
    GROUND = GROUP_GROUND,
    WORLD = GROUP_WORLD,
    WALL = GROUP_WALL,
    CEILING = GROUP_CEILING,
    PLATFORM = GROUP_PLATFORM,
    BOUNDS = GROUP_BOUNDS,
}

M.RAYCAST = {
    GROUND = ACTIVE_RAYCAST_GROUPS,
    WALL = ACTIVE_RAYCAST_GROUPS,
    CEILING = ACTIVE_RAYCAST_GROUPS,
    TERRAIN = ACTIVE_RAYCAST_GROUPS,
}

M.LAYERS = {
    PRIMARY_COLLISION = { GROUP_SOLID, GROUP_GROUND, GROUP_PLATFORM, GROUP_WALL, GROUP_CEILING, GROUP_BOUNDS },
    WALKABLE = { GROUP_SOLID, GROUP_PLATFORM, GROUP_GROUND },
}

local function normalize_id(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        return hash(value)
    end
    return value
end

function M.min_walkable_normal_y(max_slope_angle)
    local angle = tonumber(max_slope_angle) or DEFAULT_MAX_WALKABLE_SLOPE
    if angle < 0 then
        angle = 0
    elseif angle > 89.9 then
        angle = 89.9
    end
    return math.cos(math.rad(angle))
end

function M.classify_group(group)
    if group == GROUP_PLATFORM or group == GROUP_GROUND then
        return M.KINDS.GROUND
    end
    if group == GROUP_WALL then
        return M.KINDS.WALL
    end
    if group == GROUP_CEILING then
        return M.KINDS.CEILING
    end
    return M.KINDS.UNKNOWN
end

function M.classify_normal(normal, max_slope_angle)
    if not normal then
        return M.KINDS.UNKNOWN
    end

    local ny = tonumber(normal.y) or 0
    local min_y = M.min_walkable_normal_y(max_slope_angle)
    if ny >= min_y then
        return M.KINDS.GROUND
    end
    if ny <= -min_y then
        return M.KINDS.CEILING
    end
    return M.KINDS.WALL
end

function M.classify_collision(collision, max_slope_angle)
    if not collision then
        return M.KINDS.UNKNOWN
    end

    local kind = M.classify_normal(collision.normal, max_slope_angle)
    if kind ~= M.KINDS.UNKNOWN then
        return kind
    end

    return M.classify_group(collision.group or collision.other_group or collision.own_group)
end

function M.is_walkable_surface(normal, max_slope_angle)
    return M.classify_normal(normal, max_slope_angle) == M.KINDS.GROUND
end

function M.is_ground_collision(collision, max_slope_angle)
    return M.classify_collision(collision, max_slope_angle) == M.KINDS.GROUND
end

function M.is_wall_collision(collision, max_slope_angle)
    return M.classify_collision(collision, max_slope_angle) == M.KINDS.WALL
end

function M.is_ceiling_collision(collision, max_slope_angle)
    return M.classify_collision(collision, max_slope_angle) == M.KINDS.CEILING
end

function M.wall_side_from_normal(normal, fallback_dir)
    local nx = tonumber(normal and normal.x) or 0
    if nx > 0.01 then
        return -1
    end
    if nx < -0.01 then
        return 1
    end
    if fallback_dir and fallback_dir ~= 0 then
        return (fallback_dir > 0) and 1 or -1
    end
    return 0
end

function M.is_terrain_group(group)
    return group == GROUP_SOLID
        or group == GROUP_GROUND
        or group == GROUP_WORLD
        or group == GROUP_WALL
        or group == GROUP_CEILING
        or group == GROUP_PLATFORM
        or group == GROUP_BOUNDS
end

-- Layer ids of a room tilemap, from the Create Rooms manifest
-- (mvtk/rooms/tilemap_layers.lua). Defold has no tilemap.get_layers, and
-- probing a missing layer logs an engine error, so never guess by probing.
-- Returns (list of hashed ids, lookup set); both empty when the room is not in
-- the manifest (callers then fall back to trying every candidate).
function M.get_tilemap_layers(tilemap_url, room_id)
    local ok, TilemapLayers = pcall(require, "mvtk.rooms.tilemap_layers")
    if not ok or not TilemapLayers then
        return {}, {}
    end
    local ids = TilemapLayers.for_url(tilemap_url, room_id)
    if type(ids) ~= "table" then
        return {}, {}
    end
    local out = {}
    local lookup = {}
    for _, layer in ipairs(ids) do
        local id = normalize_id(layer)
        if id ~= nil then
            out[#out + 1] = id
            lookup[id] = true
        end
    end
    return out, lookup
end

function M.resolve_existing_layers(tilemap_url, candidates, room_id)
    local _, lookup = M.get_tilemap_layers(tilemap_url, room_id)
    local has_lookup = next(lookup) ~= nil
    local out = {}
    for _, candidate in ipairs(candidates or {}) do
        local id = normalize_id(candidate)
        if id ~= nil and ((not has_lookup) or lookup[id]) then
            out[#out + 1] = id
        end
    end
    return out
end

function M.resolve_first_existing_layer(tilemap_url, candidates, fallback, room_id)
    local layers = M.resolve_existing_layers(tilemap_url, candidates, room_id)
    if #layers > 0 then
        return layers[1]
    end
    return normalize_id(fallback)
end

function M.resolve_primary_collision_layer(tilemap_url, fallback, room_id)
    return M.resolve_first_existing_layer(tilemap_url, M.LAYERS.PRIMARY_COLLISION, fallback or GROUP_SOLID, room_id)
end

return M
