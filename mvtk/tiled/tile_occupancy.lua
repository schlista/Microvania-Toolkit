-- mvtk/tiled/tile_occupancy.lua
-- Shared Tiled-space occupancy checks used by validation. Supports finite and
-- chunked tile layers, nested group offsets, and encoded layer data.

local TilemapRegen = require "mvtk.editor.tilemap_regen"

local M = {}

local function tile_present(gid)
    return ((tonumber(gid) or 0) % 536870912) ~= 0
end

local function intersects(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end

local function data_has_tile(data, width, height, origin_x, origin_y, tile_w, tile_h, rect)
    width, height = tonumber(width) or 0, tonumber(height) or 0
    if type(data) ~= "table" or width <= 0 or height <= 0 then return false end
    for index, gid in ipairs(data) do
        if tile_present(gid) then
            local zero = index - 1
            local col = zero % width
            local row = math.floor(zero / width)
            if row < height and intersects(
                origin_x + col * tile_w,
                origin_y + row * tile_h,
                tile_w,
                tile_h,
                rect.x,
                rect.y,
                rect.w,
                rect.h
            ) then
                return true
            end
        end
    end
    return false
end

local function layer_has_tile(layer, room_id, tile_w, tile_h, offset_x, offset_y, rect)
    local layer_tile_x = tonumber(layer.x) or 0
    local layer_tile_y = tonumber(layer.y) or 0
    local base_x = offset_x + layer_tile_x * tile_w
    local base_y = offset_y + layer_tile_y * tile_h

    if type(layer.chunks) == "table" then
        for _, chunk in ipairs(layer.chunks) do
            local data = chunk.data
            if type(data) ~= "table" then
                data = TilemapRegen.decode_tiled_layer_data({
                    data = chunk.data,
                    encoding = chunk.encoding or layer.encoding,
                    compression = chunk.compression or layer.compression,
                }, room_id, layer.name)
            end
            if data_has_tile(
                data,
                chunk.width,
                chunk.height,
                base_x + (tonumber(chunk.x) or 0) * tile_w,
                base_y + (tonumber(chunk.y) or 0) * tile_h,
                tile_w,
                tile_h,
                rect
            ) then
                return true
            end
        end
        return false
    end

    local data = TilemapRegen.decode_tiled_layer_data(layer, room_id, layer.name)
    return data_has_tile(data, layer.width, layer.height, base_x, base_y, tile_w, tile_h, rect)
end

local function layers_have_tile(layers, room_id, tile_w, tile_h, rect, parent_x, parent_y, parent_visible, parent_opacity)
    for _, layer in ipairs(layers or {}) do
        if type(layer) == "table" then
            local visible = parent_visible and layer.visible ~= false
            local opacity = parent_opacity * (tonumber(layer.opacity) or 1)
            local offset_x = parent_x + (tonumber(layer.offsetx) or 0)
            local offset_y = parent_y + (tonumber(layer.offsety) or 0)
            if visible and opacity > 0 then
                if layer.type == "group" then
                    if layers_have_tile(layer.layers, room_id, tile_w, tile_h, rect, offset_x, offset_y, visible, opacity) then
                        return true
                    end
                elseif layer.type == "tilelayer" and not TilemapRegen.is_control_tile_layer(layer) then
                    if layer_has_tile(layer, room_id, tile_w, tile_h, offset_x, offset_y, rect) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function M.rect_has_visible_art_tile(map, object, options)
    if type(map) ~= "table" or type(object) ~= "table" then return false end
    options = options or {}
    local tile_w = tonumber(map.tilewidth) or 0
    local tile_h = tonumber(map.tileheight) or 0
    if tile_w <= 0 or tile_h <= 0 then return false end

    local rect = {
        x = (tonumber(object.x) or 0) + (tonumber(options.offset_x) or 0),
        y = (tonumber(object.y) or 0) + (tonumber(options.offset_y) or 0),
        w = tonumber(object.width) or 0,
        h = tonumber(object.height) or 0,
    }
    -- Point objects still occupy the tile under their authored position.
    if rect.w <= 0 then rect.w = 0.001 end
    if rect.h <= 0 then rect.h = 0.001 end

    return layers_have_tile(
        map.layers,
        options.room_id,
        tile_w,
        tile_h,
        rect,
        0,
        0,
        true,
        1
    )
end

return M
