-- mvtk/developer/rooms/tilemap_geometry.lua
-- Lightweight parser for .tilemap files to extract room bounds and door markers

local Util = require "mvtk.core.util"
local Tile = Util.require_config("developer.config.tile_settings")
local StreamPaths = require "mvtk.rooms.stream_paths"

local M = {}

local function parse_layers(path)
    local ok, text = pcall(sys.load_resource, path)
    if not ok or type(text) ~= "string" then
        return nil, string.format("failed to load %s: %s", tostring(path), tostring(text))
    end

    local layers = {}
    local order = {}
    local current = nil
    local cell_x, cell_y = nil, nil

    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:find("layers%s*{") then
            current = nil
            cell_x, cell_y = nil, nil
        end

        local id = trimmed:match('^id:%s*"([^"]+)"')
        if id then
            current = id
            layers[current] = layers[current] or {}
            order[#order+1] = current
        end

        local x = trimmed:match('^x:%s*(-?%d+)')
        if x then cell_x = tonumber(x) end

        local y = trimmed:match('^y:%s*(-?%d+)')
        if y then cell_y = tonumber(y) end

        local tile = trimmed:match('^tile:%s*(-?%d+)')
        if tile then
            tile = tonumber(tile)
            -- tile:0 is a valid first tile in .tilemap files, so key on cell
            -- presence (x/y parsed) rather than a non-zero tile id.
            if current and cell_x ~= nil and cell_y ~= nil then
                local t = layers[current]
                t[#t+1] = { x = cell_x, y = cell_y, tile = tile }
            end
            cell_x, cell_y = nil, nil
        end
    end

    return layers, order
end

local function make_door_entry(side, cell, min_tx, min_ty, tile_w, tile_h)
    -- Use absolute tilemap coordinates for door centers and seam positions so
    -- different rooms align on the same global tile grid even if their
    -- bounds/min-tiles differ. This avoids off-by-one tile misalignments when
    -- rooms place their "bounds" layer starting at different rows.
    local cx = (cell.x + 0.5) * tile_w
    local cy = (cell.y + 0.5) * tile_h
    local entry = {
        side = side,
        cx = cx,
        cy = cy,
    }

    if side == 'left' then
        entry.seam = (cell.x) * tile_w
        entry.len = tile_h
    elseif side == 'right' then
        entry.seam = (cell.x + 1) * tile_w
        entry.len = tile_h
    elseif side == 'top' then
        entry.seam = (cell.y + 1) * tile_h
        entry.len = tile_w
    elseif side == 'bottom' then
        entry.seam = (cell.y) * tile_h
        entry.len = tile_w
    else
        entry.seam = 0
        entry.len = tile_h
    end

    return entry
end

local function derive_extents(bounds, door_layers, layout_rec)
    local min_tx, min_ty, max_tx, max_ty
    local function consider(cell)
        if not cell then return end
        local x, y = cell.x, cell.y
        if not min_tx or x < min_tx then min_tx = x end
        if not min_ty or y < min_ty then min_ty = y end
        if not max_tx or x > max_tx then max_tx = x end
        if not max_ty or y > max_ty then max_ty = y end
    end

    if bounds then
        for _, cell in ipairs(bounds) do consider(cell) end
    end

    if door_layers then
        for _, cells in pairs(door_layers) do
            for _, cell in ipairs(cells or {}) do
                consider(cell)
            end
        end
    end

    if not min_tx then
        min_tx, min_ty = 0, 0
        local w_px = layout_rec and tonumber(layout_rec.w) or 0
        local h_px = layout_rec and tonumber(layout_rec.h) or 0
        local tile_w = Tile.width
        local tile_h = Tile.height
        local w_cells = math.max(1, math.floor((w_px > 0 and (w_px / tile_w) or 1) + 0.5))
        local h_cells = math.max(1, math.floor((h_px > 0 and (h_px / tile_h) or 1) + 0.5))
        max_tx = min_tx + w_cells - 1
        max_ty = min_ty + h_cells - 1
    else
        if not max_tx then max_tx = min_tx end
        if not max_ty then max_ty = min_ty end
    end

    return min_tx, min_ty, max_tx, max_ty
end

function M.load(room_id, layout_rec)
    if not room_id then return nil, "room_id nil" end

    local path = StreamPaths.tiled_tilemap(room_id)
    local layers, order_or_err = parse_layers(path)
    if not layers then
        return nil, order_or_err
    end
    local order = order_or_err

    local bounds = layers["bounds"]
    local door_layers = {
        left = layers["door_left"] or {},
        right = layers["door_right"] or {},
        top = layers["door_top"] or {},
        bottom = layers["door_bottom"] or {},
    }

    local min_tx, min_ty, max_tx, max_ty = derive_extents(bounds, door_layers, layout_rec)

    local tile_w = Tile.width
    local tile_h = Tile.height

    local geom = {
        min_tx = min_tx,
        min_ty = min_ty,
        max_tx = max_tx,
        max_ty = max_ty,
        tile_w = tile_w,
        tile_h = tile_h,
        w_cells = max_tx - min_tx + 1,
        h_cells = max_ty - min_ty + 1,
        doors = {
            left = {},
            right = {},
            top = {},
            bottom = {},
        }
    }

    geom.layer_ids = order

    geom.width_px = geom.w_cells * tile_w
    geom.height_px = geom.h_cells * tile_h

    for side, cells in pairs(door_layers) do
        local list = geom.doors[side]
        if list then
            for _, cell in ipairs(cells) do
                local entry = make_door_entry(side, cell, min_tx, min_ty, tile_w, tile_h)
                -- Match the bounds-relative space of exported door hints;
                -- runtime adds the bounds origin (x+ox/y+oy) afterward.
                local dx = tonumber(layout_rec and layout_rec.collection_offset_x) or 0
                local dy = tonumber(layout_rec and layout_rec.collection_offset_y) or 0
                entry.cx, entry.cy = entry.cx + dx, entry.cy + dy
                entry.seam = entry.seam + ((side == "left" or side == "right") and dx or dy)
                entry.tile_x = cell.x
                entry.tile_y = cell.y
                list[#list+1] = entry
            end
        end
    end

    -- Flatten for convenience (used by door picking elsewhere)
    local flat = {}
    for side, list in pairs(geom.doors) do
        for _, entry in ipairs(list) do
            flat[#flat+1] = {
                side = side,
                cx = entry.cx,
                cy = entry.cy,
                len = entry.len,
            }
        end
    end
    geom.door_list = flat

    return geom
end

return M
