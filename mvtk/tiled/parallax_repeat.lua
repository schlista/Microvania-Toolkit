local M = {}

-- Tiled Lua exports use a point table; JSON exports use two scalar fields.
-- Convert Tiled's downward Y to the room's upward Y once at bake time.
function M.map_origin(map)
    local point = map.parallaxorigin or {}
    local height = (map.height or 0) * (map.tileheight or 0)
    return tonumber(point.x) or tonumber(map.parallaxoriginx) or 0,
        height - (tonumber(point.y) or tonumber(map.parallaxoriginy) or 0)
end

function M.tile_instance_id(room_id, layer_id)
    return room_id .. "_parallax_tile_" .. tostring(layer_id)
end

-- Used by animation routing after moving layers have separate baked tilemaps.
function M.tile_instances(map, room_id)
    local result = {}
    local function visit(layers, px, py)
        for _, layer in ipairs(layers or {}) do
            local x = px * (tonumber(layer.parallaxx) or 1)
            local y = py * (tonumber(layer.parallaxy) or 1)
            if layer.type == "group" then visit(layer.layers, x, y)
            elseif layer.type == "tilelayer" and (x ~= 1 or y ~= 1) then
                result[layer.name] = M.tile_instance_id(room_id, layer.id)
            end
        end
    end
    visit(map.layers, 1, 1)
    return result
end

local function shallow_copy(src)
    local out = {}
    for k, v in pairs(src or {}) do
        out[k] = v
    end
    return out
end

local function overlap_index_range(base_center, sprite_size, coverage_min, coverage_max)
    local size = tonumber(sprite_size) or 0
    if size <= 0 then
        return 0, 0
    end

    local left = (tonumber(base_center) or 0) - (size * 0.5)
    local right = left + size

    local index_min = math.ceil((coverage_min - right) / size)
    local index_max = math.floor((coverage_max - left) / size)

    if index_min > index_max then
        return 0, 0
    end

    return index_min, index_max
end

local function axis_repeat_range(base_center, sprite_size, span_size, parallax_factor, is_repeating, origin)
    if not is_repeating then
        return 0, 0
    end

    local span = math.max(0, tonumber(span_size) or 0)
    -- The camera can traverse the room on either side of the Tiled origin.
    -- A factor of 1 has no relative drift; 0 needs full camera-travel coverage.
    origin = tonumber(origin) or 0
    local drift = math.max(math.abs(origin), math.abs(span-origin)) * math.abs(1-(tonumber(parallax_factor) or 1.0))

    return overlap_index_range(
        base_center,
        sprite_size,
        -drift,
        span + drift
    )
end

function M.make_component_id(base_id, repeat_x_index, repeat_y_index)
    local ix = tonumber(repeat_x_index) or 0
    local iy = tonumber(repeat_y_index) or 0
    if ix == 0 and iy == 0 then
        return tostring(base_id or "")
    end
    return string.format("%s__repeat_x%d_y%d", tostring(base_id or ""), ix, iy)
end

function M.get_base_component_id(component_id)
    local id = tostring(component_id or "")
    return id:match("^(.-)__repeat_x%-?%d+_y%-?%d+$") or id
end

function M.get_layer_name_from_component_id(component_id)
    local base_id = M.get_base_component_id(component_id)
    return base_id:match("^parallax_(.+)$")
end

function M.expand_component(comp, map_width, map_height)
    if type(comp) ~= "table" then
        return {}
    end

    local sprite_w = tonumber(comp.source_width) or 0
    local sprite_h = tonumber(comp.source_height) or 0
    local repeatx = comp.repeatx == true
    local repeaty = comp.repeaty == true

    if (not repeatx and not repeaty) or sprite_w <= 0 or sprite_h <= 0 then
        return { comp }
    end

    local x_min, x_max = axis_repeat_range(comp.pos_x, sprite_w, map_width, comp.parallaxx, repeatx, comp.parallax_origin_x)
    local y_min, y_max = axis_repeat_range(comp.pos_y, sprite_h, map_height, comp.parallaxy, repeaty, comp.parallax_origin_y)
    local expanded = {}

    for iy = y_min, y_max do
        for ix = x_min, x_max do
            local clone = shallow_copy(comp)
            clone.id = M.make_component_id(comp.id, ix, iy)
            clone.pos_x = (tonumber(comp.pos_x) or 0) + (ix * sprite_w)
            clone.pos_y = (tonumber(comp.pos_y) or 0) + (iy * sprite_h)
            expanded[#expanded + 1] = clone
        end
    end

    if #expanded == 0 then
        expanded[1] = comp
    end

    return expanded
end

return M
