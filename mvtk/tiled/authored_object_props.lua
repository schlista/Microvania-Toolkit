-- mvtk/tiled/authored_object_props.lua
-- Read authored object properties directly from exported Tiled room Lua files.

local Util = require "mvtk.core.util"
local StreamPaths = require "mvtk.rooms.stream_paths"
local PropertyFlattener = require "mvtk.tiled.property_flattener"
local EnemyOverrides = require "mvtk.enemies.enemy_overrides"

local M = {}

local room_cache = {}

local function normalize_type(value)
    if value == nil then return nil end
    local normalized = tostring(value):lower():gsub("[%s%-]+", "_")
    normalized = normalized:gsub("[^%w_]", ""):gsub("_+", "_")
    normalized = normalized:gsub("^_+", ""):gsub("_+$", "")
    return normalized ~= "" and normalized or nil
end

local function normalized_object(object)
    local copy = {}
    for key, value in pairs(object or {}) do copy[key] = value end
    local raw_properties = object and object.properties
    copy.properties = PropertyFlattener.flatten(raw_properties)
    local object_type = normalize_type(copy.type)
        or normalize_type(copy.class)
        or normalize_type(copy.className)
    if object_type == "enemy" or copy.properties.enemy_type ~= nil then
        copy.properties = EnemyOverrides.flatten_tiled_properties(raw_properties)
    end
    return copy
end

local function trim(value)
    if value == nil then
        return nil
    end
    local s = tostring(value)
    s = Util.trim(s)
    if s == "" then
        return nil
    end
    return s
end

local function index_layers(layers, out)
    if type(layers) ~= "table" then
        return
    end

    for _, layer in ipairs(layers) do
        if type(layer) == "table" then
            if layer.type == "group" and type(layer.layers) == "table" then
                index_layers(layer.layers, out)
            elseif layer.type == "objectgroup" and type(layer.objects) == "table" then
                for _, object in ipairs(layer.objects) do
                    local object_id = tonumber(object and object.id)
                    if object_id ~= nil then
                        out[object_id] = normalized_object(object)
                    end
                end
            end
        end
    end
end

local function try_load_room_map(room_id)
    local file_path = StreamPaths.tiled_map_lua(room_id)
    local ok_resource, resource_data = pcall(sys.load_resource, file_path)
    if ok_resource and resource_data then
        local chunk = loadstring(resource_data)
        if chunk then
            local ok_exec, map = pcall(chunk)
            if ok_exec and type(map) == "table" then
                return map
            end
        end
    end

    local ok_require, map = pcall(require, StreamPaths.tiled_map_module(room_id))
    if ok_require and type(map) == "table" then
        return map
    end

    return nil
end

local function load_room(room_id)
    local key = trim(room_id)
    if not key then
        return nil
    end

    if room_cache[key] ~= nil then
        return room_cache[key] or nil
    end

    local map = try_load_room_map(key)
    if type(map) ~= "table" then
        room_cache[key] = false
        return nil
    end

    local entry = {
        map = map,
        objects = {},
    }
    index_layers(map.layers, entry.objects)
    room_cache[key] = entry
    return entry
end

-- Return the raw map shared by authored-property and path consumers.
function M.get_map(room_id)
    local entry = load_room(room_id)
    return entry and entry.map or nil
end

function M.get_object(room_id, object_id)
    local entry = load_room(room_id)
    local key = tonumber(object_id)
    if not entry or key == nil then
        return nil
    end
    return entry.objects[key]
end

function M.get_properties(room_id, object_id)
    local object = M.get_object(room_id, object_id)
    if not object then
        return nil, nil
    end
    return object.properties or {}, object
end

function M.get_all_objects(room_id)
    local entry = load_room(room_id)
    if not entry then
        return nil
    end
    return entry.objects
end

function M.clear(room_id)
    local key = trim(room_id)
    if not key then
        return
    end
    room_cache[key] = nil
end

function M.clear_all()
    room_cache = {}
end

return M
