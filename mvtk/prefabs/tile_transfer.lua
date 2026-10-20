local M = {}

-- `tilemap.set_tile()` broadcasts a hull update to all collision components on
-- the game object. Avoid the broadcast when the cell already has the requested
-- value; this is both cheaper and prevents irrelevant collision warnings on
-- authored maps that have not yet been re-baked.
local function set_tile_if_changed(tilemap_url, layer_hash, tx, ty, tile_id)
    local ok_get, current = pcall(tilemap.get_tile, tilemap_url, layer_hash, tx, ty)
    if ok_get and current == tile_id then
        return true, false
    end

    local ok_set = pcall(tilemap.set_tile, tilemap_url, layer_hash, tx, ty, tile_id)
    return ok_set, ok_set
end

local function push_clear_tile(clear_map, clear_tiles, layer_hash, tx, ty, tile_id)
    if not layer_hash or not tile_id or tile_id <= 0 then
        return
    end
    local key = string.format("%s:%d:%d", tostring(layer_hash), tx, ty)
    if clear_map[key] then
        return
    end
    clear_map[key] = true
    clear_tiles[#clear_tiles + 1] = {
        x = tx,
        y = ty,
        tile_id = tile_id,
        layer = layer_hash,
    }
end

function M.find_named_layer_in_layers(layers, target_name)
    if not layers or not target_name then
        return nil
    end
    for _, layer in ipairs(layers) do
        if layer.name == target_name then
            return layer
        end
        if layer.type == "group" and layer.layers then
            local found = M.find_named_layer_in_layers(layer.layers, target_name)
            if found then
                return found
            end
        end
    end
    return nil
end

-- The current Tiled room template nests gameplay art under art/player. Keep
-- legacy environment exports working without copying bounds or other art.
function M.find_platform_art_layer(layers, has_captured_tiles)
    for _, name in ipairs({ "player", "environment" }) do
        local layer = M.find_named_layer_in_layers(layers, name)
        if layer and layer.type == "tilelayer"
            and (not has_captured_tiles or has_captured_tiles(layer)) then return layer end
    end
end

-- Collect source cells for an already-baked platform. A failed read means the
-- streamed room is not ready yet; never start moving with an uncleared source.
function M.collect_room_rectangle(opts)
    local cells, seen = {}, {}
    for ty = opts.min_ty, opts.max_ty do
        for tx = opts.min_tx, opts.max_tx do
            local ok, tile_id = pcall(tilemap.get_tile, opts.room_tilemap_url, opts.source_layer, tx, ty)
            if not ok then return nil end
            push_clear_tile(seen, cells, opts.source_layer, tx, ty, tile_id)
        end
    end
    return cells
end

function M.clear_tilemap_layer(tilemap_url, layer_hash)
    local ok_bounds, bounds_x, bounds_y, bounds_w, bounds_h = pcall(tilemap.get_bounds, tilemap_url)
    if not ok_bounds or not bounds_w or not bounds_h then
        return
    end

    local max_x = bounds_x + bounds_w - 1
    local max_y = bounds_y + bounds_h - 1
    for ty = bounds_y, max_y do
        for tx = bounds_x, max_x do
            set_tile_if_changed(tilemap_url, layer_hash, tx, ty, 0)
        end
    end
end

function M.flush_clear_tiles(room_tilemap_url, clear_tiles)
    local attempted = 0
    local applied = 0
    for _, tile_info in ipairs(clear_tiles or {}) do
        attempted = attempted + 1
        local ok_set = set_tile_if_changed(
            room_tilemap_url,
            tile_info.layer,
            tile_info.x,
            tile_info.y,
            0
        )
        if ok_set then
            applied = applied + 1
        end
    end
    return {
        attempted = attempted,
        applied = applied,
    }
end

function M.verify_clear_tiles(room_tilemap_url, clear_tiles)
    local uncleared_tiles = {}

    for _, tile_info in ipairs(clear_tiles or {}) do
        local ok_get, tile_id = pcall(tilemap.get_tile, room_tilemap_url, tile_info.layer, tile_info.x, tile_info.y)
        if not ok_get or (tile_id and tile_id > 0) then
            uncleared_tiles[#uncleared_tiles + 1] = {
                x = tile_info.x,
                y = tile_info.y,
                layer = tile_info.layer,
                tile_id = tile_id or -1,
            }
        end
    end

    return {
        cleared = #uncleared_tiles == 0,
        remaining = #uncleared_tiles,
        uncleared_tiles = uncleared_tiles,
    }
end

function M.transfer_room_tiles(opts)
    local room_tilemap_url = opts.room_tilemap_url
    local source_layer = opts.source_layer
    local room_collision_layer = opts.room_collision_layer
    local platform_tilemap = opts.platform_tilemap
    local platform_layer = opts.platform_layer
    local platform_origin_x = opts.platform_origin_x or 1
    local platform_origin_y = opts.platform_origin_y or 1
    local min_tx = opts.min_tx
    local max_tx = opts.max_tx
    local min_ty = opts.min_ty
    local max_ty = opts.max_ty
    local fill_tiles = opts.fill_tiles or {}

    local tiles_to_copy = {}
    local clear_tiles = {}
    local clear_map = {}
    local actual_min_tx, actual_max_tx = nil, nil
    local actual_min_ty, actual_max_ty = nil, nil

    for ty = min_ty, max_ty do
        for tx = min_tx, max_tx do
            local ok_get, tile_id = pcall(tilemap.get_tile, room_tilemap_url, source_layer, tx, ty)
            if ok_get and tile_id and tile_id > 0 then
                push_clear_tile(clear_map, clear_tiles, source_layer, tx, ty, tile_id)
                if not fill_tiles[tile_id] then
                    if not actual_min_tx or tx < actual_min_tx then actual_min_tx = tx end
                    if not actual_max_tx or tx > actual_max_tx then actual_max_tx = tx end
                    if not actual_min_ty or ty < actual_min_ty then actual_min_ty = ty end
                    if not actual_max_ty or ty > actual_max_ty then actual_max_ty = ty end
                    tiles_to_copy[#tiles_to_copy + 1] = {
                        tx = tx,
                        ty = ty,
                        tile_id = tile_id,
                        layer = source_layer,
                    }

                    if room_collision_layer and room_collision_layer ~= source_layer then
                        local ok_solid, solid_tile_id = pcall(tilemap.get_tile, room_tilemap_url, room_collision_layer, tx, ty)
                        if ok_solid and solid_tile_id and solid_tile_id > 0 then
                            push_clear_tile(clear_map, clear_tiles, room_collision_layer, tx, ty, solid_tile_id)
                        end
                    end
                end
            end
        end
    end

    local tiles_copied = 0
    if actual_min_tx and actual_min_ty then
        for _, tile_data in ipairs(tiles_to_copy) do
            local local_tx = (tile_data.tx - actual_min_tx) + platform_origin_x
            local local_ty = (tile_data.ty - actual_min_ty) + platform_origin_y
            local ok_set = set_tile_if_changed(
                platform_tilemap,
                platform_layer,
                local_tx,
                local_ty,
                tile_data.tile_id
            )
            if ok_set then
                tiles_copied = tiles_copied + 1
            end
        end
    end

    if tiles_copied > 0 and opts.clear_source_on_success ~= false then
        M.flush_clear_tiles(room_tilemap_url, clear_tiles)
    end

    return {
        tiles_copied = tiles_copied,
        tiles_to_copy = tiles_to_copy,
        clear_tiles = clear_tiles,
        actual_min_tx = actual_min_tx,
        actual_max_tx = actual_max_tx,
        actual_min_ty = actual_min_ty,
        actual_max_ty = actual_max_ty,
    }
end

return M
