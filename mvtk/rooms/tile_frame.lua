-- mvtk/developer/rooms/tile_frame.lua
-- Utility helpers for working with tilemap bounds and consistent room-local
-- coordinates. The frame treats the lower-left corner of the measured
-- rectangle as (0,0) and exposes conversion helpers between world space,
-- Defold map indices (min..max) and these room-local tile indices.

local Util = require "mvtk.core.util"
local Tile = Util.require_config("developer.config.tile_settings")
local StreamS = Util.require_config("developer.config.stream_settings")
local LockCfg = Util.require_config("developer.config.locked_door_settings")
local Debug = Util.require_config("developer.config.debug_config")

local M = {}

local LAYER_CACHE = {}

local hash_inner = Util.normalize_hash_string

local function layer_matches(layer_id, requested)
    if layer_id == requested then
        return true
    end
    if layer_id == nil or requested == nil then
        return false
    end

    local layer_type = type(layer_id)
    local req_type = type(requested)

    if layer_type == "string" then
        if req_type == "string" and layer_id == requested then
            return true
        end
        local ok_hash, layer_hash = pcall(hash, layer_id)
        if ok_hash and layer_hash == requested then
            return true
        end
        local req_inner = hash_inner(requested)
        if req_inner and req_inner == layer_id then
            return true
        end
    end

    if req_type == "string" then
        local ok_hash, req_hash = pcall(hash, requested)
        if ok_hash and layer_id == req_hash then
            return true
        end
        local layer_inner = hash_inner(layer_id)
        if layer_inner and layer_inner == requested then
            return true
        end
    end

    local layer_inner = hash_inner(layer_id)
    local req_inner = hash_inner(requested)
    if layer_inner and req_inner and layer_inner == req_inner then
        return true
    end

    return tostring(layer_id) == tostring(requested)
end

local function layer_set_for(tilemap_url, force_refresh)
    if not tilemap_url then return nil end
    local key = tostring(tilemap_url)
    local cached = force_refresh and nil or LAYER_CACHE[key]
    if cached ~= nil then
        return cached
    end

    -- Create Rooms manifest (mvtk/rooms/tilemap_layers.lua). Defold has no
    -- tilemap.get_layers; the URL is registered by RoomManager.get_tilemap_url.
    local ok, TilemapLayers = pcall(require, "mvtk.rooms.tilemap_layers")
    if not ok or not TilemapLayers then
        return nil
    end
    local _, set = TilemapLayers.for_url(tilemap_url)
    if not set then
        return nil
    end
    LAYER_CACHE[key] = set
    return set
end

function M.layer_exists(frame, layer_hash)
    if not (frame and frame.tilemap and layer_hash) then return false end
    -- Refresh layer metadata on each check. Streamed rooms can recreate tilemaps
    -- under reused URL strings, so a sticky cache can report layers from a
    -- previously loaded room and trigger engine errors on missing optional layers.
    local layer_set = layer_set_for(frame.tilemap, true)
    if not layer_set then
        return false
    end
    if layer_set[layer_hash] then
        return true
    end
    for layer_id, _ in pairs(layer_set) do
        if layer_matches(layer_id, layer_hash) then
            return true
        end
    end
    return false
end
local seam_log = Util.make_debug_log("[SEAM]", function()
    return (Debug.global and Debug.global.enable) or (Debug.rooms and Debug.rooms.seam)
        or (LockCfg and LockCfg.debug and LockCfg.debug.prints)
end)


local function tile_dimensions()
    local tw = (StreamS and StreamS.room and StreamS.room.tile_w) or Tile.width
    local th = (StreamS and StreamS.room and StreamS.room.tile_h) or Tile.height
    return tw, th
end

function M.build(tm_url, tm_pos)
    if not (tm_url and tm_pos) then return nil end
    local ok, min_tx, min_ty, w, h = pcall(tilemap.get_bounds, tm_url)
    if not (ok and w and h and w > 0 and h > 0) then return nil end

    local tw, th = tile_dimensions()
    local origin_x = tm_pos.x + (min_tx - 1) * tw
    local origin_y = tm_pos.y + (min_ty - 1) * th

    return {
        tilemap = tm_url,
        min_tx  = min_tx,
        min_ty  = min_ty,
        max_tx  = min_tx + w - 1,
        max_ty  = min_ty + h - 1,
        w       = w,
        h       = h,
        origin_x = origin_x,
        origin_y = origin_y,
        tile_w  = tw,
        tile_h  = th,
    }
end

local function clamp_contains(frame, map_tx, map_ty)
    return not (
        map_tx < frame.min_tx or map_tx > frame.max_tx or
        map_ty < frame.min_ty or map_ty > frame.max_ty
    )
end

function M.world_to_tiles(frame, wx, wy)
    if not (frame and wx and wy) then return nil end
    local lx = (wx - frame.origin_x) / frame.tile_w
    local ly = (wy - frame.origin_y) / frame.tile_h
    local local_tx = math.floor(lx)
    local local_ty = math.floor(ly)
    if local_tx < 0 or local_tx >= frame.w or local_ty < 0 or local_ty >= frame.h then
        return nil
    end
    local map_tx = frame.min_tx + local_tx
    local map_ty = frame.min_ty + local_ty
    return map_tx, map_ty, local_tx, local_ty
end

function M.map_to_world_center(frame, map_tx, map_ty)
    if not (frame and map_tx and map_ty) then return nil end
    if not clamp_contains(frame, map_tx, map_ty) then return nil end
    local local_tx = map_tx - frame.min_tx
    local local_ty = map_ty - frame.min_ty
    return M.local_to_world_center(frame, local_tx, local_ty)
end

function M.local_to_world_center(frame, local_tx, local_ty)
    if not (frame and local_tx and local_ty) then return nil end
    local wx = frame.origin_x + (local_tx + 0.5) * frame.tile_w
    local wy = frame.origin_y + (local_ty + 0.5) * frame.tile_h
    return wx, wy
end

function M.is_tile_filled(frame, layer_hash, map_tx, map_ty)
    if not (frame and frame.tilemap and layer_hash and map_tx and map_ty) then return false end
    if not clamp_contains(frame, map_tx, map_ty) then return false end
    if not M.layer_exists(frame, layer_hash) then return false end
    local ok, tid = pcall(tilemap.get_tile, frame.tilemap, layer_hash, map_tx, map_ty)
    if not ok then
        return false
    end
    return (tid or 0) ~= 0
end

-- Debug helpers
function M.debug_dump(frame, label)
    if not frame then seam_log('[SEAM_DBG] frame=nil ' .. tostring(label or '')) return end
    seam_log(string.format('[SEAM_DBG] frame(%s) origin=(%.1f,%.1f) min=(%d,%d) size=%dx%d tiles=(%d x %d) px=(%d x %d) max=(%d,%d)'
        , tostring(label or ''), frame.origin_x, frame.origin_y, frame.min_tx, frame.min_ty
        , frame.w, frame.h, frame.tile_w, frame.tile_h, frame.w * frame.tile_w, frame.h * frame.tile_h
        , frame.max_tx, frame.max_ty))
end

local function name_to_hash(name) return name and name ~= '' and hash(name) or nil end

function M.sample_layer(frame, layer_hash, map_tx, map_ty, radius)
    if not (frame and layer_hash and map_tx and map_ty) then return '<no-sample>' end
    local r = tonumber(radius) or 2
    local out = {}
    local layer_set = layer_set_for(frame.tilemap, true)
    if not layer_set then
        return '<missing-layer>'
    end
    local exists = false
    if layer_set[layer_hash] then
        exists = true
    else
        for layer_id, _ in pairs(layer_set) do
            if layer_matches(layer_id, layer_hash) then
                exists = true
                break
            end
        end
    end
    if not exists then
        return '<missing-layer>'
    end

    local function inside_bounds(tx, ty)
        return tx >= frame.min_tx and tx <= frame.max_tx and ty >= frame.min_ty and ty <= frame.max_ty
    end

    for ty = map_ty + r, map_ty - r, -1 do
        local row = {}
        for tx = map_tx - r, map_tx + r do
            local ch_l = ' . '
            if tx == map_tx and ty == map_ty then ch_l = '[' end
            if tx == map_tx + 1 and ty == map_ty then ch_l = ']' end

            local tid = 0
            if inside_bounds(tx, ty) then
                local ok, t = pcall(tilemap.get_tile, frame.tilemap, layer_hash, tx, ty)
                if ok then tid = t or 0 end
            else
                tid = 0 -- out of bounds treated as empty, and we avoid calling into engine
            end

            row[#row + 1] = (tid ~= 0) and ' X ' or ' . '
        end
        out[#out + 1] = table.concat(row)
    end
    return table.concat(out, '\n')
end

function M.sample_layer_by_name(frame, layer_name, map_tx, map_ty, radius)
    return M.sample_layer(frame, name_to_hash(layer_name), map_tx, map_ty, radius)
end

return M
