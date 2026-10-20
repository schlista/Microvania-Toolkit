-- mvtk/rooms/tilemap_layers.lua
-- Which layers exist in a room's tilemap, from the baked manifest
-- developer/config/room_tilemap_layers_generated.lua (written by Create Rooms).
--
-- Defold's tilemap API cannot list layers (there is no tilemap.get_layers),
-- and tilemap.get_tile on a missing layer logs
-- "ERROR:GAMESYS: Could not find layer '<name>'" even inside pcall. Use this
-- module instead of probing.
local Util = require "mvtk.core.util"
local M = {}

local manifest = nil
-- tostring(tilemap url) -> room id, registered by RoomManager when it locates
-- a room's tilemap. Module-wide on purpose: one registry for the session.
local url_rooms = {}

local function load_manifest()
    if manifest ~= nil then return manifest end
    local ok, data = pcall(require, "developer.config.room_tilemap_layers_generated")
    manifest = (ok and type(data) == "table" and type(data.rooms) == "table") and data.rooms or false
    return manifest
end

local function normalize_room(room_id)
    local s = Util.normalize_hash_string(room_id)
    if not s then return nil end
    s = s:gsub("^/", ""):gsub("%.collection$", ""):gsub("^developer/rooms/", "")
    if s == "" then return nil end
    return s
end

--- Remember that a tilemap URL belongs to a room.
function M.register(tilemap_url, room_id)
    local room = normalize_room(room_id)
    if tilemap_url ~= nil and room then url_rooms[tostring(tilemap_url)] = room end
end

--- Ordered layer ids and a lookup set for a room, or nil when unknown
-- (the room was generated before the manifest existed: re-run Create Rooms).
function M.for_room(room_id)
    local rooms = load_manifest()
    local room = normalize_room(room_id)
    local list = rooms and room and rooms[room]
    if type(list) ~= "table" then return nil, nil end
    local lookup = {}
    for _, id in ipairs(list) do
        lookup[id] = true
        if type(hash) == "function" then lookup[hash(id)] = true end
    end
    return list, lookup
end

--- Same as for_room, resolving the room from a registered tilemap URL when
-- room_id is not given.
function M.for_url(tilemap_url, room_id)
    local room = room_id or (tilemap_url ~= nil and url_rooms[tostring(tilemap_url)]) or nil
    return M.for_room(room)
end

--- true / false when known; nil when the manifest has no entry.
function M.has_layer(room_id, layer)
    local _, lookup = M.for_room(room_id)
    if not lookup then return nil end
    return lookup[layer] == true
end

-- Test hook: replace the manifest ({ [room] = { ids } }) or reset to lazy load.
function M._set_manifest(rooms)
    manifest = rooms
    url_rooms = {}
end

return M
