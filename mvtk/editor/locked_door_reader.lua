-- mvtk/editor/locked_door_reader.lua
-- Classify authored locked doors from the Tiled Lua export.

local M = {}

local function project_tile_width()
    local ok, Tile = pcall(require, "developer.config.tile_settings")
    local w = ok and Tile and tonumber(Tile.width or Tile.tile_width or Tile.size) or nil
    return (w and w > 0) and w or 128
end

local function project_tile_height()
    local ok, Tile = pcall(require, "developer.config.tile_settings")
    local h = ok and Tile and tonumber(Tile.height or Tile.tile_height or Tile.size) or nil
    return (h and h > 0) and h or project_tile_width()
end

local function normalize_token(value)
    if value == nil then
        return ""
    end
    local token = tostring(value):lower()
    token = token:gsub("[%s%-]+", "_")
    token = token:gsub("[^%w_]+", "")
    return token
end

local function is_true(value)
    if value == true then
        return true
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        local token = normalize_token(value)
        return token == "true" or token == "1" or token == "yes" or token == "on"
    end
    return false
end

local function read_text(path)
    if not path or path == "" then
        return nil
    end

    local resource_path = path
    if resource_path:sub(1, 1) ~= "/" then
        resource_path = "/" .. resource_path
    end

    if sys and sys.load_resource then
        local ok, text = pcall(sys.load_resource, resource_path)
        if ok and type(text) == "string" and #text > 0 then
            return text
        end
    end

    if io and io.open then
        local file_path = resource_path:gsub("^/", "")
        local handle = io.open(file_path, "rb")
        if handle then
            local text = handle:read("*a")
            handle:close()
            if text and #text > 0 then
                return text
            end
        end
    end

    return nil
end

local function load_tiled_export(tilemap_path, reader)
    if not tilemap_path or tilemap_path == "" then
        return nil
    end

    local lua_path = tostring(tilemap_path):gsub("%.tilemap$", ".lua")
    if lua_path == tilemap_path then
        return nil
    end

    local text = (reader or read_text)(lua_path)
    if not text then
        return nil
    end

    local loader = loadstring or load
    if not loader then
        return nil
    end

    local chunk, load_err = loader(text)
    if not chunk then
        print(string.format("[LOCKED_DOOR_READER] Failed to compile %s: %s", tostring(lua_path), tostring(load_err)))
        return nil
    end

    local ok, result = pcall(chunk)
    if ok and type(result) == "table" then
        return result
    end

    print(string.format("[LOCKED_DOOR_READER] Failed to execute %s: %s", tostring(lua_path), tostring(result)))
    return nil
end

local function visit_layers(layers, fn)
    if type(layers) ~= "table" then
        return
    end

    for _, layer in ipairs(layers) do
        fn(layer)
        if layer.type == "group" and type(layer.layers) == "table" then
            visit_layers(layer.layers, fn)
        end
    end
end

local function visit_nonzero_cells(layer, fn)
    if type(layer) ~= "table" then
        return
    end

    local function scan_array(data, width, base_x, base_y)
        width = tonumber(width)
        if type(data) ~= "table" or not width or width <= 0 then
            return
        end

        base_x = tonumber(base_x) or 0
        base_y = tonumber(base_y) or 0

        for index, tile in ipairs(data) do
            if tonumber(tile) and tonumber(tile) ~= 0 then
                local zero = index - 1
                local col = zero % width
                local row = math.floor(zero / width)
                fn(base_x + col, base_y + row)
            end
        end
    end

    if type(layer.chunks) == "table" and #layer.chunks > 0 then
        for _, chunk in ipairs(layer.chunks) do
            scan_array(chunk.data, chunk.width, chunk.x, chunk.y)
        end
        return
    end

    scan_array(layer.data, layer.width, layer.x, layer.y)
end

local function extract_bounds(exported_map)
    if type(exported_map) ~= "table" then
        return nil
    end

    local tile_w = tonumber(exported_map.tilewidth) or project_tile_width()
    local tile_h = tonumber(exported_map.tileheight) or tile_w or project_tile_height()
    local min_col, min_row = math.huge, math.huge
    local max_col, max_row = -math.huge, -math.huge

    visit_layers(exported_map.layers, function(layer)
        if layer.type ~= "tilelayer" then
            return
        end
        if normalize_token(layer.name or layer.id) ~= "bounds" then
            return
        end

        visit_nonzero_cells(layer, function(col, row)
            if col < min_col then min_col = col end
            if row < min_row then min_row = row end
            if col > max_col then max_col = col end
            if row > max_row then max_row = row end
        end)
    end)

    if min_col == math.huge or min_row == math.huge then
        return {
            left_px = 0,
            bottom_px = (tonumber(exported_map.height) or 0) * tile_h,
            tile_w = tile_w,
            tile_h = tile_h,
        }
    end

    return {
        left_px = min_col * tile_w,
        bottom_px = (max_row + 1) * tile_h,
        tile_w = tile_w,
        tile_h = tile_h,
    }
end

local function locked_door_props(obj)
    return type(obj and obj.properties) == "table" and obj.properties or {}
end

local function looks_like_locked_door(obj)
    if type(obj) ~= "table" then
        return false
    end

    local type_token = normalize_token((obj.type ~= "" and obj.type) or obj.class)
    local name_token = normalize_token(obj.name)
    if type_token == "locked_door" then
        return true
    end
    if name_token:find("locked", 1, true) and name_token:find("door", 1, true) then
        return true
    end

    local props = locked_door_props(obj)
    if props.door_id ~= nil then
        return props.starts_locked ~= nil
            or props.require_ability ~= nil
            or props.require_key ~= nil
            or props.require_item ~= nil
            or props.consume_key ~= nil
            or props.unlock_message ~= nil
    end

    return false
end

local function object_is_locked(obj)
    local props = locked_door_props(obj)
    if props.starts_locked == nil then
        return true
    end
    return is_true(props.starts_locked)
end

local function collect_locked_door_rects(exported_map)
    if type(exported_map) ~= "table" then
        return {}
    end

    local bounds = extract_bounds(exported_map)
    if not bounds then
        return {}
    end

    local rects = {}
    visit_layers(exported_map.layers, function(layer)
        if layer.type ~= "objectgroup" or type(layer.objects) ~= "table" then
            return
        end

        for _, obj in ipairs(layer.objects) do
            if looks_like_locked_door(obj) and object_is_locked(obj) then
                local width = tonumber(obj.width) or bounds.tile_w
                local height = tonumber(obj.height) or bounds.tile_h
                if width <= 0 then width = bounds.tile_w end
                if height <= 0 then height = bounds.tile_h end

                local x0 = (tonumber(obj.x) or 0) - bounds.left_px
                local x1 = x0 + width
                local y1 = bounds.bottom_px - (tonumber(obj.y) or 0)
                local y0 = y1 - height

                rects[#rects + 1] = {
                    x0 = x0,
                    y0 = y0,
                    x1 = x1,
                    y1 = y1,
                }
            end
        end
    end)

    return rects
end

local function overlaps(a0, a1, b0, b1, padding)
    padding = tonumber(padding) or 0
    return math.min(a1, b1) + padding >= math.max(a0, b0) - padding
end

local function rect_matches_door(rect, door, padding)
    local door_x0 = math.min(door.x0 or 0, door.x1 or 0)
    local door_x1 = math.max(door.x0 or 0, door.x1 or 0)
    local door_y0 = math.min(door.y0 or 0, door.y1 or 0)
    local door_y1 = math.max(door.y0 or 0, door.y1 or 0)
    local side = normalize_token(door.side)

    if side == "left" or side == "right" then
        local cx = (door_x0 + door_x1) * 0.5
        return cx >= rect.x0 - padding
            and cx <= rect.x1 + padding
            and overlaps(door_y0, door_y1, rect.y0, rect.y1, padding)
    end

    if side == "up" or side == "top" or side == "down" or side == "bottom" then
        local cy = (door_y0 + door_y1) * 0.5
        return cy >= rect.y0 - padding
            and cy <= rect.y1 + padding
            and overlaps(door_x0, door_x1, rect.x0, rect.x1, padding)
    end

    return overlaps(door_x0, door_x1, rect.x0, rect.x1, padding)
        and overlaps(door_y0, door_y1, rect.y0, rect.y1, padding)
end

function M.classify_locked_doors(tilemap_path, shape, doors, reader)
    if type(doors) ~= "table" or #doors == 0 then
        return {}
    end

    local exported_map = load_tiled_export(tilemap_path, reader)
    if not exported_map then
        local out = {}
        for i = 1, #doors do
            out[i] = "open"
        end
        return out
    end

    local tile_w = tonumber(shape and shape.tile_w) or tonumber(exported_map.tilewidth) or project_tile_width()
    local tile_h = tonumber(shape and shape.tile_h) or tonumber(exported_map.tileheight) or tile_w or project_tile_height()
    local padding = math.max(8, math.floor(math.min(tile_w, tile_h) * 0.15))
    local rects = collect_locked_door_rects(exported_map)
    local out = {}

    for index, door in ipairs(doors) do
        local state = "open"
        for _, rect in ipairs(rects) do
            if rect_matches_door(rect, door, padding) then
                state = "locked"
                break
            end
        end
        out[index] = state
    end

    return out
end

return M
