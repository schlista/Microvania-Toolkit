-- One alpha-mask texture per GUI, rebuilt on discovery/mapping changes.
local Discovery = require "mvtk.map.discovery"
local Config = require("developer.config.runtime_settings").section("map_discovery",require "developer.config.map_discovery_settings")
local DynamicTexture = require "mvtk.ui.dynamic_texture"
local Time = require "mvtk.core.time"
local M = {}
local HIDDEN, SHOWN = string.char(0, 0, 0, 255), string.char(0, 0, 0, 0)
local ALPHA, FEATHER = {}, {}
for a = 0, 255 do
    ALPHA[a] = string.char(a)
    -- Keep the explored interior clear and the distant fog fully opaque.
    local t = math.max(0, math.min(1, (a / 255 - 0.15) / 0.7))
    FEATHER[a] = string.char(0, 0, 0, math.floor(t * t * (3 - 2 * t) * 255 + 0.5))
end

-- Separable coverage filter: rounds corners and feathers the contour. Packed
-- intermediate rows avoid a Lua number table per texel; identical rows reuse
-- their filtered result. This runs only when the cached mask is rebuilt.
function M.soften(pixels, width, height, radius_x, radius_y)
    local rx = math.min(width, math.max(0, math.floor(radius_x + 0.5)))
    local ry = math.min(height, math.max(0, math.floor(radius_y + 0.5)))
    if rx == 0 and ry == 0 then return pixels end
    local rows, previous, filtered = {}, nil, nil
    local stride, divisor = width * 4, 2 * rx + 1
    local black, clear = string.rep(HIDDEN, width), string.rep(SHOWN, width)
    for y = 1, height do
        local source = pixels:sub((y - 1) * stride + 1, y * stride)
        if source ~= previous then
            if source == black or source == clear then
                filtered = string.rep(source == black and ALPHA[255] or ALPHA[0], width)
            else
                local sum, row = 0, {}
                for x = 1 - rx, 1 + rx do
                    sum = sum + source:byte(math.max(1, math.min(width, x)) * 4)
                end
                for x = 1, width do
                    row[x] = ALPHA[math.floor(sum / divisor + 0.5)]
                    sum = sum - source:byte(math.max(1, x - rx) * 4)
                        + source:byte(math.min(width, x + rx + 1) * 4)
                end
                filtered = table.concat(row)
            end
            previous = source
        end
        rows[y] = filtered
    end
    local sums, output = {}, {}
    for x = 1, width do sums[x] = 0 end
    divisor = 2 * ry + 1
    for y = 1 - ry, 1 + ry do
        local row = rows[math.max(1, math.min(height, y))]
        for x = 1, width do sums[x] = sums[x] + row:byte(x) end
    end
    local changed = true
    for y = 1, height do
        if changed then
            local row = {}
            for x = 1, width do row[x] = FEATHER[math.floor(sums[x] / divisor + 0.5)] end
            filtered = table.concat(row)
        end
        output[y] = filtered
        local leaving = rows[math.max(1, y - ry)]
        local entering = rows[math.min(height, y + ry + 1)]
        changed = leaving ~= entering
        if changed then
            for x = 1, width do sums[x] = sums[x] - leaving:byte(x) + entering:byte(x) end
        end
    end
    return table.concat(output)
end

-- Pure rasterization seam for regression tests and native visual verification.
function M.rasterize(rects, width, height, world)
    local rows = {}
    local sx, sy = width / (world.max_x - world.min_x), height / (world.max_y - world.min_y)
    for _, rect in ipairs(rects) do
        -- Sample pixel centers with the same rounding at both edges. Rounding
        -- each cell inward leaves opaque seams between adjacent explored cells.
        local x0 = math.max(0, math.ceil((rect.min_x - world.min_x) * sx - 0.5))
        local x1 = math.min(width, math.ceil((rect.max_x - world.min_x) * sx - 0.5))
        local y0 = math.max(0, math.ceil((rect.min_y - world.min_y) * sy - 0.5))
        local y1 = math.min(height, math.ceil((rect.max_y - world.min_y) * sy - 0.5))
        if x1 > x0 then
            for y = y0, y1 - 1 do
                rows[y] = rows[y] or {}
                rows[y][#rows[y] + 1] = { x0, x1 }
            end
        end
    end
    local output = {}
    for y = 0, height - 1 do
        local intervals = rows[y] or {}
        table.sort(intervals, function(a, b) return a[1] < b[1] end)
        local chunks, cursor, end_x = {}, 0, 0
        for _, interval in ipairs(intervals) do
            local left, right = interval[1], interval[2]
            if left > end_x then
                chunks[#chunks + 1] = string.rep(SHOWN, end_x - cursor)
                chunks[#chunks + 1] = string.rep(HIDDEN, left - end_x)
                cursor = left
            end
            end_x = math.max(end_x, right)
        end
        chunks[#chunks + 1] = string.rep(SHOWN, end_x - cursor)
        chunks[#chunks + 1] = string.rep(HIDDEN, width - end_x)
        output[#output + 1] = table.concat(chunks)
    end
    return table.concat(output)
end

-- Secret rooms remain fully opaque after ordinary fog has been feathered.
-- Cover every intersecting texel plus a one-texel sampling margin so bilinear
-- filtering cannot disclose a sliver of the room behind an intact wall.
function M.conceal(pixels, rects, width, height, world)
    if #rects == 0 then return pixels end
    local sx, sy = width / (world.max_x - world.min_x), height / (world.max_y - world.min_y)
    local rows = {}
    for _, rect in ipairs(rects) do
        local x0 = math.max(0, math.floor((rect.min_x - world.min_x) * sx) - 1)
        local x1 = math.min(width, math.ceil((rect.max_x - world.min_x) * sx) + 1)
        local y0 = math.max(0, math.floor((rect.min_y - world.min_y) * sy) - 1)
        local y1 = math.min(height, math.ceil((rect.max_y - world.min_y) * sy) + 1)
        if x1 > x0 then
            local cover = string.rep(HIDDEN, x1 - x0)
            for y = y0, y1 - 1 do
                local row = rows[y] or pixels:sub(y * width * 4 + 1, (y + 1) * width * 4)
                rows[y] = row:sub(1, x0 * 4) .. cover .. row:sub(x1 * 4 + 1)
            end
        end
    end
    local result = {}
    for y = 0, height - 1 do
        result[y + 1] = rows[y] or pixels:sub(y * width * 4 + 1, (y + 1) * width * 4)
    end
    return table.concat(result)
end

function M.create(parent, pivot, texture_name)
    local node = gui.new_box_node(vmath.vector3(0, 0, 0.001), vmath.vector3(1, 1, 0))
    gui.set_parent(node, parent, false)
    gui.set_pivot(node, pivot)
    -- Fail closed until the first valid texture is ready.
    gui.set_color(node, vmath.vector4(0, 0, 0, 1))
    return { node = node, texture_name = texture_name }
end

function M.update(view, width, height, world)
    local mask_enabled = Discovery.mask_enabled()
    gui.set_enabled(view.node, mask_enabled)
    if not mask_enabled then return end
    local revision = Discovery.revision()
    local softness = math.max(0, tonumber(Config.edge_softness) or 0)
    local same_shape = view.width == width and view.height == height
        and view.softness == softness
        and view.min_x == world.min_x and view.min_y == world.min_y
        and view.max_x == world.max_x and view.max_y == world.max_y
    if same_shape then
        if view.revision == revision then return end
        local interval = math.max(0, tonumber(Config.rebuild_interval) or 0.25)
        if Time.gettime() - (view.built_at or -math.huge) < interval then return end
    end
    gui.set_size(view.node, vmath.vector3(width, height, 0))
    local limit = math.max(16, math.floor(tonumber(Config.texture_max_size) or 512))
    local ratio = math.min(1, limit / math.max(width, height))
    local tw, th = math.max(1, math.ceil(width * ratio)), math.max(1, math.ceil(height * ratio))
    local pixels = Discovery.enabled() and M.rasterize(Discovery.rectangles(), tw, th, world)
        or string.rep(SHOWN, tw * th)
    if softness > 0 then
        pixels = M.soften(pixels, tw, th, softness * tw / (world.max_x - world.min_x),
            softness * th / (world.max_y - world.min_y))
        gui.set_material(view.node, "fog")
    else
        gui.reset_material(view.node)
    end
    pixels = M.conceal(pixels, Discovery.hidden_rectangles(), tw, th, world)
    -- Raster rows start at world min_y; GUI texture buffers start at the top.
    if DynamicTexture.update(view.texture_name, tw, th, pixels, { format = "rgba", flip = true }) then
        gui.set_texture(view.node, view.texture_name)
        gui.set_color(view.node, vmath.vector4(1, 1, 1, 1))
        view.revision, view.width, view.height = revision, width, height
        view.softness = softness
        view.min_x, view.min_y, view.max_x, view.max_y = world.min_x, world.min_y, world.max_x, world.max_y
        view.built_at = Time.gettime()
    end
end

return M
