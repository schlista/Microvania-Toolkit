-- mvtk/rooms/stream_paths.lua
-- Shared path resolver for Tiled exports and generated room resources.

local Util = require "mvtk.core.util"

local M = {}

local DEFAULT_TILED_MAPS_DIR = "/developer" .. "/assets/tiled/maps/"
local DEFAULT_GENERATED_ROOMS_DIR = "/developer" .. "/rooms/generated/"
local DEFAULT_BACKGROUNDS_TEMPLATE = DEFAULT_GENERATED_ROOMS_DIR .. "<room_id>_backgrounds_meta.lua"

local Settings = Util.require_config("developer.config.stream_settings", {})

local function text_or_nil(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil
    end
    return text
end

local function setting(name, fallback)
    local value = text_or_nil(Settings[name])
    if value ~= nil then
        return value
    end
    if type(Settings.paths) == "table" then
        value = text_or_nil(Settings.paths[name])
        if value ~= nil then
            return value
        end
    end
    return fallback
end

local function normalize_dir(path)
    path = text_or_nil(path) or ""
    path = path:gsub("\\", "/"):gsub("/+", "/")
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end
    return path
end

local function join(dir, name)
    return normalize_dir(dir) .. tostring(name or ""):gsub("^/+", "")
end

function M.tiled_maps_dir()
    return normalize_dir(setting("tiled_maps_dir", DEFAULT_TILED_MAPS_DIR))
end

function M.generated_rooms_dir()
    return normalize_dir(setting("generated_rooms_dir", DEFAULT_GENERATED_ROOMS_DIR))
end

function M.room_backgrounds_meta_template()
    return setting("room_backgrounds_meta_template", DEFAULT_BACKGROUNDS_TEMPLATE)
end

function M.tiled_map_lua(room_id)
    return join(M.tiled_maps_dir(), tostring(room_id) .. ".lua")
end

function M.tiled_tilemap(room_id)
    return join(M.tiled_maps_dir(), tostring(room_id) .. ".tilemap")
end

function M.backgrounds_meta(room_id)
    local template = M.room_backgrounds_meta_template()
    return template:gsub("<room_id>", tostring(room_id))
end

function M.tiled_maps_fs_dir()
    return M.tiled_maps_dir():gsub("^/+", ""):gsub("/+$", "")
end

function M.tiled_maps_module_prefix()
    return M.tiled_maps_fs_dir():gsub("/", ".")
end

function M.tiled_map_module(room_id)
    return M.tiled_maps_module_prefix() .. "." .. tostring(room_id)
end

return M
