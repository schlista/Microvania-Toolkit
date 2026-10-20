-- mvtk/game/spawn_registry.lua
-- Global registry for Tiled spawn points (player start/checkpoints).

local M = {}
local Util = require "mvtk.core.util"

local spawn_points = {}
local default_id = nil

local normalize_id = Util.normalize_hash_string

local function normalize_spawn_type(value)
    if not value then return nil end
    local s = tostring(value)
    if s == "" then return nil end
    return s:lower()
end

function M.register(entry)
    if not entry then return false, "no_entry" end
    local id = normalize_id(entry.id)
    if not id then return false, "no_id" end
    local checkpoint_id = normalize_id(entry.checkpoint_id)

    spawn_points[id] = {
        id = id,
        position = entry.position,
        room_id = entry.room_id,
        spawn_type = normalize_spawn_type(entry.spawn_type),
        facing = entry.facing,
        is_default = entry.is_default == true,
        checkpoint_id = checkpoint_id,
        name = entry.name,
        properties = entry.properties,
    }

    if spawn_points[id].is_default then
        default_id = id
    end

    return true
end

function M.unregister(id)
    local key = normalize_id(id)
    if not key then return false end
    if spawn_points[key] then
        spawn_points[key] = nil
        if default_id == key then
            default_id = nil
        end
        return true
    end
    return false
end

function M.get(id)
    local key = normalize_id(id)
    if not key then return nil end
    return spawn_points[key]
end

function M.get_by_checkpoint_id(checkpoint_id)
    local key = normalize_id(checkpoint_id)
    if not key then return nil end
    for _, sp in pairs(spawn_points) do
        if sp.checkpoint_id == key then
            return sp
        end
    end
    return nil
end

function M.get_default()
    if default_id and spawn_points[default_id] then
        return spawn_points[default_id]
    end

    local fallback = nil
    for _, sp in pairs(spawn_points) do
        if sp.spawn_type == "player" or sp.spawn_type == "start" then
            return sp
        end
        if not fallback then
            fallback = sp
        end
    end

    return fallback
end

function M.clear()
    spawn_points = {}
    default_id = nil
end

function M.all()
    return spawn_points
end

function M.count()
    local n = 0
    for _ in pairs(spawn_points) do n = n + 1 end
    return n
end

return M
