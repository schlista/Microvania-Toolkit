-- hooks/core/elevator_resources.lua
--
-- Pure helpers used by Create Rooms to move authored elevator cabin art out
-- of a streamed room tilemap and into a persistent, factory-spawned cabin.
-- This module deliberately performs no file I/O so the extraction contract
-- can be covered by the plain-Lua test suite.

local Contract = require "mvtk.elevators.elevator_contract"
local ProtoUtils = require "mvtk.editor.proto_utils"

local M = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalize_layer_id(value)
    return trim(value):lower():gsub("[%s%-]+", "_"):gsub("_+", "_")
end

local function split_lines(text)
    text = tostring(text or "")
    local use_crlf = text:find("\r\n", 1, true) ~= nil
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        lines[#lines + 1] = line
    end
    if #lines > 0 and lines[#lines] == "" then
        lines[#lines] = nil
    end
    return lines, use_crlf
end

local function parse_cell(lines)
    local blob = table.concat(lines or {}, "\n")
    local x = tonumber(blob:match("x:%s*(-?%d+)"))
    local y = tonumber(blob:match("y:%s*(-?%d+)"))
    if x == nil or y == nil then
        return nil
    end
    return {
        x = x,
        y = y,
        tile = tonumber(blob:match("tile:%s*(-?%d+)")) or 0,
        h_flip = tonumber(blob:match("h_flip:%s*(-?%d+)")) or 0,
        v_flip = tonumber(blob:match("v_flip:%s*(-?%d+)")) or 0,
        rotate90 = tonumber(blob:match("rotate90:%s*(-?%d+)")) or 0,
    }
end

-- Parse the small, stable subset of Defold's tilemap protobuf text that the
-- toolkit emits. Unknown top-level and per-layer fields are retained.
function M.parse_tilemap(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty_tilemap"
    end

    local lines, use_crlf = split_lines(text)
    local parsed = {
        top_lines = {},
        tail_lines = {},
        layers = {},
        use_crlf = use_crlf,
    }
    local current_layer = nil
    local current_cell = nil
    local saw_layer = false

    local function finish_layer()
        local blob = table.concat(current_layer.pre_lines, "\n")
        current_layer.id = blob:match('id:%s*"([^"]+)"') or ""
        current_layer.z = tonumber(blob:match("z:%s*([%-+%deE%.]+)"))
        current_layer.is_visible = tonumber(blob:match("is_visible:%s*(-?%d+)"))
        parsed.layers[#parsed.layers + 1] = current_layer
        current_layer = nil
    end

    for _, line in ipairs(lines) do
        if not current_layer then
            if line:match("^%s*layers%s*{%s*$") then
                saw_layer = true
                current_layer = {
                    open_line = line,
                    pre_lines = {},
                    cells = {},
                }
            elseif saw_layer then
                parsed.tail_lines[#parsed.tail_lines + 1] = line
            else
                parsed.top_lines[#parsed.top_lines + 1] = line
            end
        elseif current_cell then
            current_cell[#current_cell + 1] = line
            if line:match("}%s*$") then
                local cell = parse_cell(current_cell)
                if cell then current_layer.cells[#current_layer.cells + 1] = cell end
                current_cell = nil
            end
        else
            if line:match("^%s*cell%s*{") then
                if line:match("}%s*$") then
                    local cell = parse_cell({ line })
                    if cell then current_layer.cells[#current_layer.cells + 1] = cell end
                else
                    current_cell = { line }
                end
            elseif line:match("^%s*}%s*$") then
                finish_layer()
            else
                current_layer.pre_lines[#current_layer.pre_lines + 1] = line
            end
        end
    end

    if current_cell or current_layer then
        return nil, "unterminated_tilemap_block"
    end
    if #parsed.layers == 0 then
        return nil, "no_tilemap_layers"
    end

    local header = table.concat(parsed.top_lines, "\n")
    parsed.tile_set = header:match('tile_set:%s*"([^"]+)"')
    if not parsed.tile_set then
        return nil, "missing_tilesource"
    end
    return parsed
end

local function emit_cell(lines, cell)
    lines[#lines + 1] = "  cell {"
    lines[#lines + 1] = "    x: " .. tostring(math.floor(tonumber(cell.x) or 0))
    lines[#lines + 1] = "    y: " .. tostring(math.floor(tonumber(cell.y) or 0))
    lines[#lines + 1] = "    tile: " .. tostring(math.floor(tonumber(cell.tile) or 0))
    lines[#lines + 1] = "    h_flip: " .. tostring(math.floor(tonumber(cell.h_flip) or 0))
    lines[#lines + 1] = "    v_flip: " .. tostring(math.floor(tonumber(cell.v_flip) or 0))
    lines[#lines + 1] = "    rotate90: " .. tostring(math.floor(tonumber(cell.rotate90) or 0))
    lines[#lines + 1] = "  }"
end

function M.serialize_tilemap(parsed)
    local lines = {}
    for _, line in ipairs(parsed.top_lines or {}) do lines[#lines + 1] = line end
    for _, layer in ipairs(parsed.layers or {}) do
        lines[#lines + 1] = layer.open_line or "layers {"
        for _, line in ipairs(layer.pre_lines or {}) do lines[#lines + 1] = line end
        for _, cell in ipairs(layer.cells or {}) do emit_cell(lines, cell) end
        lines[#lines + 1] = "}"
    end
    for _, line in ipairs(parsed.tail_lines or {}) do lines[#lines + 1] = line end
    local sep = parsed.use_crlf and "\r\n" or "\n"
    return table.concat(lines, sep) .. sep
end

local function positive_number(value, name)
    local number = tonumber(value)
    if not number or number <= 0 or number ~= number or number == math.huge then
        return nil, "invalid_" .. name
    end
    return number
end

local function aligned(value, step)
    local quotient = value / step
    return math.abs(quotient - math.floor(quotient + 0.5)) < 0.000001
end

-- Convert the Tiled-space capture rectangle (Y down) to the zero-based,
-- Y-up cell coordinates written by mvtk.editor.tilemap_regen.
function M.capture_bounds(opts)
    opts = opts or {}
    local tile_w, err = positive_number(opts.tile_width, "tile_width")
    if not tile_w then return nil, err end
    local tile_h
    tile_h, err = positive_number(opts.tile_height or opts.tile_width, "tile_height")
    if not tile_h then return nil, err end
    local map_h
    map_h, err = positive_number(opts.map_height, "map_height")
    if not map_h then return nil, err end

    local x = tonumber(opts.x) or 0
    local y = tonumber(opts.y) or 0
    local width
    width, err = positive_number(opts.width, "width")
    if not width then return nil, err end
    local height
    height, err = positive_number(opts.height, "height")
    if not height then return nil, err end

    if not aligned(x, tile_w) or not aligned(y, tile_h)
        or not aligned(width, tile_w) or not aligned(height, tile_h)
    then
        return nil, "capture_not_tile_aligned"
    end

    local min_x = math.floor(x / tile_w + 0.5)
    local top_row = math.floor(y / tile_h + 0.5)
    local tiles_wide = math.floor(width / tile_w + 0.5)
    local tiles_tall = math.floor(height / tile_h + 0.5)
    local min_y = map_h - top_row - tiles_tall
    local max_y = min_y + tiles_tall - 1
    if min_x < 0 or min_y < 0 or (min_x + tiles_wide) > (tonumber(opts.map_width) or math.huge)
        or max_y >= map_h
    then
        return nil, "capture_outside_map"
    end

    return {
        min_x = min_x,
        max_x = min_x + tiles_wide - 1,
        min_y = min_y,
        max_y = max_y,
        tiles_wide = tiles_wide,
        tiles_tall = tiles_tall,
        pixel_width = width,
        pixel_height = height,
    }
end

local function copy_cell(cell, dx, dy)
    return {
        x = cell.x + dx,
        y = cell.y + dy,
        tile = cell.tile,
        h_flip = cell.h_flip,
        v_flip = cell.v_flip,
        rotate90 = cell.rotate90,
    }
end

local function cell_order(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
end

local function cabin_tilemap(parsed, cells, bounds)
    local lines = {
        string.format('tile_set: "%s"', parsed.tile_set),
        'material: "/builtins/materials/tile_map.material"',
        "blend_mode: BLEND_MODE_ALPHA",
        "",
        "layers {",
        '  id: "solid"',
        -- visual_z belongs to the persistent cabin GO. Keeping the copied
        -- tilemap local prevents the authored depth from being applied twice.
        "  z: 0",
        "  is_visible: 1",
    }
    table.sort(cells, cell_order)
    for _, cell in ipairs(cells) do emit_cell(lines, cell) end

    -- Keep the authored rectangle's complete dimensions in the tilemap bounds,
    -- even when transparent edge cells contain no art. Defold derives bounds
    -- from cells, so explicit tile-0 sentinels are unsafe (tile 0 is real art).
    -- The collision dimensions remain authoritative for cabin size.
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    local sep = parsed.use_crlf and "\r\n" or "\n"
    return table.concat(lines, sep), bounds
end

-- Extract only cells from the named art layer. Other visual/collision layers
-- are left untouched; static collision exclusion is handled separately by the
-- room collision baker using the same elevator rectangle.
function M.extract_cabin(source_text, opts)
    opts = opts or {}
    local parsed, parse_err = M.parse_tilemap(source_text)
    if not parsed then return nil, parse_err end
    local bounds, bounds_err = M.capture_bounds(opts)
    if not bounds then return nil, bounds_err end

    local wanted = normalize_layer_id(opts.layer_name or "environment")
    local found_layer = false
    local extracted = {}

    for _, layer in ipairs(parsed.layers) do
        if normalize_layer_id(layer.id) == wanted then
            found_layer = true
            local retained = {}
            for _, cell in ipairs(layer.cells or {}) do
                if cell.x >= bounds.min_x and cell.x <= bounds.max_x
                    and cell.y >= bounds.min_y and cell.y <= bounds.max_y
                then
                    extracted[#extracted + 1] = copy_cell(cell, -bounds.min_x, -bounds.min_y)
                else
                    retained[#retained + 1] = cell
                end
            end
            layer.cells = retained
        end
    end

    if not found_layer then return nil, "missing_source_layer:" .. wanted end
    if #extracted == 0 then return nil, "empty_elevator_cabin_art" end

    local cabin_text = cabin_tilemap(parsed, extracted, bounds)
    return {
        source_tilemap = M.serialize_tilemap(parsed),
        cabin_tilemap = cabin_text,
        tile_set = parsed.tile_set,
        copied_cells = #extracted,
        removed_cells = #extracted,
        bounds = bounds,
    }
end

function M.resource_key(elevator_id)
    return Contract.resource_key(elevator_id)
end

function M.expected_generated_files(manifest)
    local expected = {
        generated = {},
        collections = {},
        factories = {},
    }
    for _, elevator_id in ipairs((manifest and manifest.ordered_ids) or {}) do
        local elevator = manifest.elevators and manifest.elevators[elevator_id]
        if elevator and elevator.valid ~= false and elevator.resource_key then
            local bundle = Contract.resource_bundle(elevator.resource_key)
            expected.generated[bundle.tilemap_name] = true
            expected.generated[bundle.cabin_go_name] = true
            expected.generated[bundle.collision_go_name] = true
            expected.collections[bundle.collection_name] = true
            expected.factories[bundle.factory_name] = true
        end
    end
    return expected
end

-- Reconcile only the dedicated generated-elevator directories. The caller
-- supplies filesystem operations so this remains testable without Defold and
-- cannot accidentally broaden cleanup to ordinary room resources.
function M.reconcile_generated_resources(manifest, directories, deps)
    directories = directories or {}
    deps = deps or {}
    if type(deps.list_dir) ~= "function" or type(deps.remove) ~= "function"
        or type(deps.join) ~= "function" or type(deps.exists) ~= "function"
    then
        return nil, "missing_elevator_reconcile_dependency"
    end

    local expected = M.expected_generated_files(manifest)
    local removed = {}
    local preserved = {}
    local owned_filename = {
        generated = function(name)
            return name:match("^[%w_]+%.tilemap$") ~= nil
                or name:match("^[%w_]+%.go$") ~= nil
        end,
        collections = function(name)
            return name:match("^[%w_]+%.collection$") ~= nil
        end,
        factories = function(name)
            return name:match("^[%w_]+_factory%.collectionfactory$") ~= nil
        end,
    }
    for _, kind in ipairs({ "generated", "collections", "factories" }) do
        local directory = directories[kind]
        if type(directory) ~= "string" or directory == "" then
            return nil, "missing_elevator_resource_directory:" .. kind
        end
        local child_dirs, files = deps.list_dir(directory, { force_process = true })
        child_dirs = child_dirs or {}
        files = files or {}
        table.sort(child_dirs)
        table.sort(files)

        local stale = {}
        for _, name in ipairs(files) do
            if not expected[kind][name] and owned_filename[kind](name) then
                stale[#stale + 1] = name
            elseif not expected[kind][name] then
                preserved[#preserved + 1] = deps.join(directory, name)
            end
        end
        -- The generator does not create nested directories. Preserve rather
        -- than recursively delete an unexpected one: a reserved prefix is not
        -- enough evidence to destroy an unrecognized directory tree.
        for _, name in ipairs(child_dirs) do
            preserved[#preserved + 1] = deps.join(directory, name)
        end
        table.sort(stale)

        for _, name in ipairs(stale) do
            local path = deps.join(directory, name)
            local ok, remove_error = deps.remove(path)
            if not ok then
                return nil, string.format("cannot_remove_stale_elevator_resource:%s:%s",
                    tostring(path), tostring(remove_error or "remove failed"))
            end
            if deps.exists(path) then
                return nil, "stale_elevator_resource_still_exists:" .. tostring(path)
            end
            removed[#removed + 1] = path
            if type(deps.info) == "function" then
                deps.info("Removed stale generated elevator resource " .. tostring(path))
            end
        end
    end
    table.sort(preserved)
    if type(deps.info) == "function" then
        for _, path in ipairs(preserved) do
            deps.info("[ELEVATOR_RESOURCES][WARNING] Preserved unrecognized entry "
                .. "in generated elevator directory " .. tostring(path))
        end
    end
    return { removed = removed, preserved = preserved, expected = expected }
end

local proto_escape = ProtoUtils.proto_escape

local function append_property(lines, id, value, property_type)
    lines[#lines + 1] = "    properties {"
    lines[#lines + 1] = string.format('      id: "%s"', proto_escape(id))
    lines[#lines + 1] = string.format('      value: "%s"', proto_escape(value))
    lines[#lines + 1] = "      type: " .. tostring(property_type)
    lines[#lines + 1] = "    }"
end

function M.generate_cabin_go(tilemap_resource)
    return table.concat({
        "components {",
        '  id: "script"',
        '  component: "/mvtk/prefabs/elevator_cabin.script"',
        "}",
        "components {",
        '  id: "tilemap"',
        string.format('  component: "%s"', proto_escape(tilemap_resource)),
        "}",
        "",
    }, "\n")
end


-- The persistent collection has a stable `cabin` root id so the runtime can
-- address the object returned by collectionfactory.create without depending
-- on a room collection or spawn generation. World-space endpoint properties
-- are supplied by the runtime layout resolver when the factory is invoked.
function M.generate_cabin_collection(opts)
    opts = opts or {}
    local resource_key = tostring(opts.resource_key or "")
    local root_resource = tostring(opts.root_resource or "")
    local collision_resource = tostring(opts.collision_resource or "")
    if resource_key == "" or root_resource == "" or collision_resource == "" then
        return nil, "missing_cabin_collection_resource"
    end

    local lines = {
        string.format('name: "%s"', proto_escape(resource_key)),
        "instances {",
        '  id: "cabin"',
        string.format('  prototype: "%s"', proto_escape(root_resource)),
        "  component_properties {",
        '    id: "script"',
    }
    append_property(lines, "elevator_id", opts.elevator_id or "", "PROPERTY_TYPE_TEXT")
    append_property(lines, "trigger_id", opts.trigger_id or opts.elevator_id or "", "PROPERTY_TYPE_TEXT")
    append_property(lines, "cabin_resource_key", resource_key, "PROPERTY_TYPE_TEXT")
    append_property(lines, "width", tonumber(opts.width) or 0, "PROPERTY_TYPE_NUMBER")
    append_property(lines, "height", tonumber(opts.height) or 0, "PROPERTY_TYPE_NUMBER")
    append_property(lines, "carry_player", opts.carry_player == false and "false" or "true", "PROPERTY_TYPE_BOOLEAN")
    append_property(lines, "enabled", opts.enabled == false and "false" or "true", "PROPERTY_TYPE_BOOLEAN")
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = '  children: "collision"'
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "instances {"
    lines[#lines + 1] = '  id: "collision"'
    lines[#lines + 1] = string.format('  prototype: "%s"', proto_escape(collision_resource))
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

function M.generate_collection_factory(collection_resource)
    local resource = trim(collection_resource)
    if resource == "" then return nil, "missing_collection_resource" end
    return string.format('prototype: "%s"\n', proto_escape(resource))
end

return M
