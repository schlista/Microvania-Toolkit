-- mvtk/editor/tilemap_regen.lua
-- Regenerate Defold .tilemap files from Tiled .lua exports.
--
-- The Tiled .lua export is the source of truth: artists author in Tiled and
-- export Lua, this module transforms that into the Defold .tilemap proto so
-- the user never has to hand-edit .tilemap files.
--
-- Tiled layer data may arrive base64-encoded with optional zlib/gzip
-- compression. The decompression path tries lua_zlib first; if that fails,
-- it shells out to Python or PowerShell so users without lua_zlib still get
-- correct tilemaps. Decompression scratch files are written under
-- hooks/.mvtk_tiled_layer_<token>.{bin,out} and removed on completion.
--
-- Wiring: editor_core.lua calls M.configure{...} once with the collaborators
-- that live there (writers, shell runner, profiler, tilesource resolver,
-- Tiled property reader, logger). Without configuration the module errors
-- on first use to fail loudly rather than silently mis-generate.

local path_utils = require("mvtk.editor.path_utils")
local file_utils = require("mvtk.editor.file_utils")
local proto_utils = require("mvtk.editor.proto_utils")
local tiled_export = require("mvtk.editor.tiled_export")
local tileset_selection = require("mvtk.editor.tileset_selection")

local M = {}

-- Collaborator slots populated via configure().
local _logger = function(msg) print("[tilemap_regen] " .. tostring(msg)) end
local _profiler = nil
local _write_text = nil
local _write_binary = nil
local _run_shell = nil
local _run_process = nil
local _resolve_tilesource = nil
local _get_tiled_property = nil

-- Tiled GID flip bits and tile-id mask. Encoded into the high bits of a GID
-- to mark horizontal/vertical/diagonal flips before extracting the tile id.
local TILED_FLIP_H_BIT = 2147483648  -- 0x80000000
local TILED_FLIP_V_BIT = 1073741824  -- 0x40000000
local TILED_FLIP_D_BIT = 536870912   -- 0x20000000
local TILED_GID_MASK   = 536870911   -- 0x1FFFFFFF
M.TILED_GID_MASK = TILED_GID_MASK

function M.configure(opts)
    opts = opts or {}
    if opts.logger ~= nil then _logger = opts.logger end
    if opts.profiler ~= nil then _profiler = opts.profiler end
    if opts.write_text ~= nil then _write_text = opts.write_text end
    if opts.write_binary ~= nil then _write_binary = opts.write_binary end
    if opts.run_shell ~= nil then _run_shell = opts.run_shell end
    if opts.run_process ~= nil then _run_process = opts.run_process end
    if opts.resolve_tilesource ~= nil then _resolve_tilesource = opts.resolve_tilesource end
    if opts.get_tiled_property ~= nil then _get_tiled_property = opts.get_tiled_property end
end

local function require_collab(name, value)
    assert(value, "mvtk.editor.tilemap_regen: missing collaborator '" .. name
        .. "'; configure{} must supply it before calling regenerate(...)")
    return value
end

local function profiler_start(label)
    if _profiler and _profiler.start then _profiler.start(label) end
end

local function profiler_stop(label)
    if _profiler and _profiler.stop then _profiler.stop(label) end
end

-- ── GID + layer decoding ──────────────────────────────────────────────

local function decode_gid(raw)
    local value = tonumber(raw) or 0
    local h, v, d = 0, 0, 0
    if value >= TILED_FLIP_H_BIT then h = 1; value = value - TILED_FLIP_H_BIT end
    if value >= TILED_FLIP_V_BIT then v = 1; value = value - TILED_FLIP_V_BIT end
    if value >= TILED_FLIP_D_BIT then d = 1; value = value - TILED_FLIP_D_BIT end
    if value < 0 then value = 0 end
    if value > TILED_GID_MASK then value = value % (TILED_GID_MASK + 1) end
    return value, h, v, d
end
M.decode_gid = decode_gid
M.tiled_flags_to_defold = tileset_selection.tiled_flags_to_defold

local function collect_tile_layers_flat(layers, out)
    if type(layers) ~= "table" then return end
    for _, layer in ipairs(layers) do
        if type(layer) == "table" then
            if layer.type == "group" and type(layer.layers) == "table" then
                collect_tile_layers_flat(layer.layers, out)
            elseif layer.type == "tilelayer" then
                out[#out + 1] = layer
            end
        end
    end
end
M.collect_tile_layers_flat = collect_tile_layers_flat

-- Keep control/collision tiles below the imported background image band
-- (-0.15..-0.01), matching the native Tiled exporter extension.
local CONTROL_LAYER_Z_BASE = -0.3

local CONTROL_LAYER_NAMES = {
    bounds = true,
    grapple = true,
    solid = true,
    wall = true,
    walls = true,
    ceiling = true,
    ceilings = true,
    ground = true,
    floor = true,
    floors = true,
    collision = true,
    collisions = true,
    locked_door = true,
    door_left = true,
    door_right = true,
    door_top = true,
    door_bottom = true,
    door_up = true,
    door_down = true,
}

local function normalize_layer_name(name)
    local s = tostring(name or ""):lower()
    s = s:gsub("[%s%-]+", "_")
    s = s:gsub("[^%w_]", "_")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    return s
end
M.normalize_layer_name = normalize_layer_name

local function is_control_tile_layer(layer)
    local layer_name = normalize_layer_name(type(layer) == "table" and (layer.name or layer.id) or layer)
    return CONTROL_LAYER_NAMES[layer_name] and true or false
end
M.is_control_tile_layer = is_control_tile_layer

local function layer_z_value(layer, layer_index)
    if _get_tiled_property and type(layer) == "table" then
        local authored_z = _get_tiled_property(layer.properties, "defold_z")
        if authored_z ~= nil and tonumber(authored_z) ~= nil then
            return tonumber(authored_z)
        end
    end

    local index = tonumber(layer_index) or 1
    if is_control_tile_layer(layer) then
        return CONTROL_LAYER_Z_BASE + (index * 1e-4)
    end
    return index * 1e-4
end
M.layer_z_value = layer_z_value

local function tiled_layer_temp_token(room_id, layer_name)
    local token = string.format("%s_%s", tostring(room_id or "room"), tostring(layer_name or "layer"))
    token = token:gsub("[^%w_%-]+", "_")
    token = token:gsub("_+", "_")
    token = token:gsub("^_+", "")
    token = token:gsub("_+$", "")
    if token == "" then
        token = "layer"
    end
    return token
end

local function shell_quote_arg(value)
    local text = tostring(value or "")
    if path_utils.DIR_SEP == "\\" then
        return '"' .. text:gsub('"', '""') .. '"'
    end
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function powershell_single_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

-- ── Base64 + decompression ────────────────────────────────────────────

local BASE64_DECODE_MAP = {}
do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #chars do
        BASE64_DECODE_MAP[chars:sub(i, i)] = i - 1
    end
end

local function base64_decode_bytes(data)
    local cleaned = tostring(data or ""):gsub("%s+", "")
    if cleaned == "" then
        return ""
    end

    local out = {}
    local buffer = 0
    local bits = 0

    for i = 1, #cleaned do
        local ch = cleaned:sub(i, i)
        if ch == "=" then
            break
        end
        local value = BASE64_DECODE_MAP[ch]
        if value ~= nil then
            buffer = (buffer * 64) + value
            bits = bits + 6
            while bits >= 8 do
                local shift = bits - 8
                local byte = math.floor(buffer / (2 ^ shift))
                buffer = buffer % (2 ^ shift)
                bits = shift
                out[#out + 1] = string.char(byte)
            end
        end
    end

    return table.concat(out)
end

local function try_lua_zlib_decompress(raw, compression)
    local ok_lib, zlib = pcall(require, "zlib")
    if not ok_lib or type(zlib) ~= "table" then
        return nil, "lua_zlib_unavailable"
    end

    if type(zlib.decompress) == "function" then
        local ok_dec, result = pcall(zlib.decompress, raw)
        if ok_dec and type(result) == "string" then
            return result
        end
    end

    if compression == "zlib" and type(zlib.inflate) == "function" then
        local ok_stream, stream = pcall(zlib.inflate)
        if ok_stream and type(stream) == "function" then
            local ok_dec, result = pcall(stream, raw)
            if ok_dec and type(result) == "string" then
                return result
            end
        end
    end

    return nil, "lua_zlib_decode_failed"
end

local function try_external_tiled_decompress(raw, compression, room_id, layer_name)
    require_collab("write_binary", _write_binary)
    assert(_run_process or _run_shell,
        "mvtk.editor.tilemap_regen: configure{} must supply run_process or run_shell")

    local root = path_utils.get_root()
    local token = tiled_layer_temp_token(room_id, layer_name)
    local input_path = path_utils.normalize(
        path_utils.join(root, "hooks", ".mvtk_tiled_layer_" .. token .. ".bin"))
    local output_path = path_utils.normalize(
        path_utils.join(root, "hooks", ".mvtk_tiled_layer_" .. token .. ".out"))

    _write_binary(input_path, raw)
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
    pcall(os.remove, output_path)

    local output = nil
    local attempts = {}

    local py_code = "import gzip,pathlib,sys,zlib; raw=pathlib.Path(sys.argv[1]).read_bytes(); c=sys.argv[3]; raw=(zlib.decompress(raw) if c=='zlib' else gzip.decompress(raw) if c=='gzip' else raw); pathlib.Path(sys.argv[2]).write_bytes(raw)"
    local python_commands = {
        { command = "python3", args = { "-c" } },
        { command = "python", args = { "-c" } },
    }
    if path_utils.DIR_SEP == "\\" then
        python_commands[#python_commands + 1] = { command = "py", args = { "-3", "-c" } }
    end

    for _, candidate in ipairs(python_commands) do
        local args = {}
        for _, arg in ipairs(candidate.args) do args[#args + 1] = arg end
        args[#args + 1] = py_code
        args[#args + 1] = path_utils.to_os_path(input_path)
        args[#args + 1] = path_utils.to_os_path(output_path)
        args[#args + 1] = compression
        local ok
        if _run_process then
            ok = _run_process(candidate.command, args, {
                capture = true,
                reload_resources = false,
            })
        else
            local cmd = shell_quote_arg(candidate.command)
            for _, arg in ipairs(args) do cmd = cmd .. " " .. shell_quote_arg(arg) end
            ok = _run_shell(cmd, 0)
        end
        attempts[#attempts + 1] = candidate.command
        if ok and file_utils.file_exists(output_path) then
            output = file_utils.read_text(output_path)
            if type(output) == "string" then
                break
            end
        end
    end

    if not output and path_utils.DIR_SEP == "\\" then
        local stream_type = (compression == "gzip") and "GZipStream" or "ZLibStream"
        local ps_script = table.concat({
            "$in=" .. powershell_single_quote(path_utils.to_os_path(input_path)) .. ";",
            "$out=" .. powershell_single_quote(path_utils.to_os_path(output_path)) .. ";",
            "$raw=[System.IO.File]::ReadAllBytes($in);",
            "$ms=New-Object System.IO.MemoryStream(,$raw);",
            "$zs=New-Object System.IO.Compression." .. stream_type .. "($ms,[System.IO.Compression.CompressionMode]::Decompress);",
            "$fs=[System.IO.File]::Open($out,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None);",
            "$zs.CopyTo($fs);",
            "$fs.Dispose();",
            "$zs.Dispose();",
            "$ms.Dispose();",
        }, " ")
        local ok
        if _run_process then
            ok = _run_process("powershell", {
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_script,
            }, {
                capture = true,
                reload_resources = false,
            })
        else
            local cmd = "powershell -NoProfile -ExecutionPolicy Bypass -Command " .. shell_quote_arg(ps_script)
            ok = _run_shell(cmd, 0)
        end
        attempts[#attempts + 1] = "powershell"
        if ok and file_utils.file_exists(output_path) then
            output = file_utils.read_text(output_path)
        end
    end

    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end

    pcall(os.remove, input_path)
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("removes") end
    pcall(os.remove, output_path)

    if type(output) == "string" then
        return output
    end

    return nil, "Could not decode compressed Tiled layer via "
        .. table.concat(attempts, ", ")
        .. ". Install python3, or set the map's Tile Layer Format to CSV in Tiled."
end

local function decode_tiled_layer_data(layer, room_id, layer_name)
    if type(layer) ~= "table" then
        return nil, "invalid_layer"
    end

    if type(layer.data) == "table" then
        return layer.data
    end

    if type(layer.data) ~= "string" or layer.data == "" then
        return nil, "missing_layer_data"
    end

    local encoding = tostring(layer.encoding or ""):lower()
    local compression = tostring(layer.compression or ""):lower()
    if encoding ~= "base64" then
        return nil, "unsupported_encoding:" .. tostring(encoding)
    end

    local raw = base64_decode_bytes(layer.data)
    if type(raw) ~= "string" then
        return nil, "base64_decode_failed"
    end

    if compression == "zlib" or compression == "gzip" then
        local decoded, err = try_lua_zlib_decompress(raw, compression)
        if not decoded then
            decoded, err = try_external_tiled_decompress(raw, compression, room_id, layer_name)
        end
        if not decoded then
            return nil, err or ("unsupported_compression:" .. compression)
        end
        raw = decoded
    elseif compression ~= "" then
        return nil, "unsupported_compression:" .. tostring(compression)
    end

    if (#raw % 4) ~= 0 then
        return nil, "decoded_byte_count_not_multiple_of_4"
    end

    local gids = {}
    for i = 1, #raw, 4 do
        local b1, b2, b3, b4 = raw:byte(i, i + 3)
        gids[#gids + 1] = (b1 or 0)
            + ((b2 or 0) * 256)
            + ((b3 or 0) * 65536)
            + ((b4 or 0) * 16777216)
    end

    return gids
end
M.decode_tiled_layer_data = decode_tiled_layer_data

-- ── Diff logging (compares the existing .tilemap with the regenerated one) ─

local function parse_tilemap_diag(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    local parsed = { layers = {} }
    local current_layer = nil
    local current_cell = nil

    local function finalize_cell(lines)
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
        }
    end

    for _, line in ipairs(proto_utils.split_text_lines(text)) do
        if not current_layer then
            if line:match("^%s*layers%s*{%s*$") then
                current_layer = { id = "", cells = {} }
            end
        elseif current_cell then
            current_cell[#current_cell + 1] = line
            if line:match("^%s*}%s*$") then
                local cell = finalize_cell(current_cell)
                if cell then
                    current_layer.cells[#current_layer.cells + 1] = cell
                end
                current_cell = nil
            end
        else
            local layer_id = line:match('^%s*id:%s*"([^"]+)"')
            if layer_id then
                current_layer.id = layer_id
            elseif line:match("^%s*cell%s*{%s*$") then
                current_cell = { line }
            elseif line:match("^%s*}%s*$") then
                parsed.layers[#parsed.layers + 1] = current_layer
                current_layer = nil
            end
        end
    end

    return parsed
end

local function build_diag_layer_state(parsed)
    local state = {}
    for _, layer in ipairs((parsed and parsed.layers) or {}) do
        local layer_id = tostring(layer.id or "")
        local cells = {}
        local count = 0
        for _, cell in ipairs(layer.cells or {}) do
            local tx = tonumber(cell.x)
            local ty = tonumber(cell.y)
            local tid = math.floor(tonumber(cell.tile) or 0)
            if tx ~= nil and ty ~= nil and tid ~= 0 then
                cells[string.format("%d,%d", tx, ty)] = tid
                count = count + 1
            end
        end
        state[layer_id] = {
            count = count,
            cells = cells,
        }
    end
    return state
end

local function collect_changed_tile_keys(before_cells, after_cells)
    local keys = {}
    local seen = {}

    local function add_key(key)
        if not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end

    for key in pairs(before_cells or {}) do
        if (before_cells[key] or 0) ~= (after_cells[key] or 0) then
            add_key(key)
        end
    end
    for key in pairs(after_cells or {}) do
        if (before_cells[key] or 0) ~= (after_cells[key] or 0) then
            add_key(key)
        end
    end

    table.sort(keys, function(a, b)
        local ax, ay = a:match("(-?%d+),(-?%d+)")
        local bx, by = b:match("(-?%d+),(-?%d+)")
        ax, ay = tonumber(ax) or 0, tonumber(ay) or 0
        bx, by = tonumber(bx) or 0, tonumber(by) or 0
        if ay ~= by then
            return ay < by
        end
        return ax < bx
    end)

    return keys
end

local function log_tilemap_regen_diff(room_id, before_content, after_content)
    local before_state = build_diag_layer_state(parse_tilemap_diag(before_content))
    local after_state = build_diag_layer_state(parse_tilemap_diag(after_content))

    local layer_ids = {}
    local seen = {}
    for layer_id in pairs(before_state or {}) do
        seen[layer_id] = true
        layer_ids[#layer_ids + 1] = layer_id
    end
    for layer_id in pairs(after_state or {}) do
        if not seen[layer_id] then
            layer_ids[#layer_ids + 1] = layer_id
        end
    end
    table.sort(layer_ids)

    local logged = 0
    for _, layer_id in ipairs(layer_ids) do
        local before_layer = before_state[layer_id] or { count = 0, cells = {} }
        local after_layer = after_state[layer_id] or { count = 0, cells = {} }
        local changed_keys = collect_changed_tile_keys(before_layer.cells, after_layer.cells)
        if #changed_keys > 0 or before_layer.count ~= after_layer.count then
            local samples = {}
            for i = 1, math.min(#changed_keys, 8) do
                local key = changed_keys[i]
                local tx, ty = key:match("(-?%d+),(-?%d+)")
                samples[#samples + 1] = string.format("(%s,%s):%s->%s",
                    tostring(tx),
                    tostring(ty),
                    tostring(before_layer.cells[key] or 0),
                    tostring(after_layer.cells[key] or 0))
            end
            _logger(string.format(
                "[REGEN_TILEMAP] room=%s layer=%s before=%d after=%d changed=%d%s",
                tostring(room_id),
                tostring(layer_id ~= "" and layer_id or "<unnamed>"),
                tonumber(before_layer.count) or 0,
                tonumber(after_layer.count) or 0,
                #changed_keys,
                (#samples > 0) and (" samples=" .. table.concat(samples, ", ")) or ""
            ))
            logged = logged + 1
        end
    end

    if logged == 0 then
        _logger(string.format("[REGEN_TILEMAP] room=%s no layer diffs detected", tostring(room_id)))
    end
end

-- ── Public API ─────────────────────────────────────────────────────────

--- Regenerate a Defold .tilemap file from the Tiled Lua export for a room.
-- Reads the exported .lua (source of truth) and writes a fresh .tilemap so
-- the user only needs to export the .lua from Tiled.
-- @param room_id  Room identifier (e.g. "desert4")
-- @return true on success, false/nil + reason on failure
function M.regenerate(room_id)
    require_collab("write_text", _write_text)
    require_collab("resolve_tilesource", _resolve_tilesource)
    require_collab("get_tiled_property", _get_tiled_property)

    local tiled_data, tiled_export_path = tiled_export.load(room_id)
    if not tiled_data then
        return false, "load_failed: " .. tostring(tiled_export_path)
    end

    -- Determine tilesource path for the tile_set header
    local primary_tileset = tileset_selection.select_primary_tileset(tiled_data, _get_tiled_property)
    if not primary_tileset then
        return false, "no_tileset"
    end

    local firstgid, lastgid = tileset_selection.get_tileset_gid_range(
        tiled_data,
        primary_tileset,
        TILED_GID_MASK
    )

    -- Resolve the Defold tilesource resource path
    local tileset_name = tostring(primary_tileset.name or "")
    local tilesource = _resolve_tilesource(tileset_name)
    if not tilesource then
        tilesource = string.format("/developer/assets/tilesheets/%s.tilesource", tileset_name)
    end

    -- Collect all tile layers (flattened from groups)
    local tile_layers = {}
    collect_tile_layers_flat(tiled_data.layers, tile_layers)

    local map_height = tonumber(tiled_data.height) or 0
    local map_width  = tonumber(tiled_data.width) or 0

    -- Build .tilemap content
    local lines = {}
    lines[#lines + 1] = string.format('tile_set: "%s"', tilesource)

    for layer_index, layer in ipairs(tile_layers) do
        local layer_name = tostring(layer.name or ("layer_" .. layer_index))
        local z_value = layer_z_value(layer, layer_index)
        -- Grapple paint marks baked static surfaces, never in-game tile art.
        local is_visible = (normalize_layer_name(layer_name) ~= "grapple" and layer.visible ~= false) and 1 or 0

        lines[#lines + 1] = "layers {"
        lines[#lines + 1] = string.format('  id: "%s"', layer_name)
        lines[#lines + 1] = string.format("  z: %s", tostring(z_value))
        lines[#lines + 1] = string.format("  is_visible: %d", is_visible)

        local layer_data, layer_err = decode_tiled_layer_data(layer, room_id, layer_name)
        if type(layer_data) == "table" then
            local width = tonumber(layer.width) or map_width
            for i, raw_gid in ipairs(layer_data) do
                local gid, flip_h, flip_v, flip_d = decode_gid(raw_gid)
                if gid >= firstgid and gid <= lastgid then
                    local defold_h, defold_v, defold_r = tileset_selection.tiled_flags_to_defold(flip_h, flip_v, flip_d)
                    local tile = gid - firstgid  -- 0-based tile index
                    -- Convert Tiled row/col to Defold coordinates
                    -- Tiled data is top-to-bottom; Defold tilemap Y is bottom-to-top
                    local col = (i - 1) % width
                    local row = math.floor((i - 1) / width)
                    local defold_x = col
                    local defold_y = (map_height - 1) - row

                    lines[#lines + 1] = "  cell {"
                    lines[#lines + 1] = string.format("    x: %d", defold_x)
                    lines[#lines + 1] = string.format("    y: %d", defold_y)
                    lines[#lines + 1] = string.format("    tile: %d", tile)
                    lines[#lines + 1] = string.format("    h_flip: %d", defold_h)
                    lines[#lines + 1] = string.format("    v_flip: %d", defold_v)
                    lines[#lines + 1] = string.format("    rotate90: %d", defold_r)
                    lines[#lines + 1] = "  }"
                end
            end
        else
            _logger(string.format(
                "[REGEN_TILEMAP] room=%s layer=%s skipped (%s)",
                tostring(room_id),
                tostring(layer_name),
                tostring(layer_err)
            ))
        end

        lines[#lines + 1] = "}"
    end

    lines[#lines + 1] = 'material: "/builtins/materials/tile_map.material"'
    lines[#lines + 1] = "blend_mode: BLEND_MODE_ALPHA"
    lines[#lines + 1] = ""

    local content = table.concat(lines, "\n")

    -- Write to the tilemap path
    local _, tiled_tilemaps_path = tiled_export.get_paths()
    local root = path_utils.get_root()
    local tilemap_path = path_utils.normalize(
        path_utils.join(root, tiled_tilemaps_path, room_id .. ".tilemap"))
    local existing_content = file_utils.read_text(tilemap_path)

    local lua_mtime, lua_size = file_utils.get_file_signature(tiled_export_path)
    local tilemap_mtime, tilemap_size = file_utils.get_file_signature(tilemap_path)
    _logger(string.format(
        "[REGEN_TILEMAP] room=%s lua=%s lua_mtime=%s lua_size=%s tilemap=%s tilemap_mtime=%s tilemap_size=%s",
        tostring(room_id),
        tostring(tiled_export_path),
        tostring(lua_mtime),
        tostring(lua_size),
        tostring(tilemap_path),
        tostring(tilemap_mtime),
        tostring(tilemap_size)
    ))
    log_tilemap_regen_diff(room_id, existing_content, content)

    if _write_text(tilemap_path, content) then
        _logger("Regenerated tilemap from Lua export: " .. tilemap_path)
    else
        _logger("[REGEN_TILEMAP] No file write needed for " .. tilemap_path)
    end

    return true
end

function M.regenerate_all(room_ids)
    local count = 0
    for _, rid in ipairs(room_ids or {}) do
        local ok, err = M.regenerate(rid)
        if ok then
            count = count + 1
        else
            _logger("regenerate_tilemap_from_lua: skipped " .. tostring(rid)
                .. " (" .. tostring(err) .. ")")
        end
    end
    _logger("regenerate_all_tilemaps_from_lua: regenerated " .. count
        .. " / " .. #(room_ids or {}) .. " tilemaps")
end

-- Exposed for diagnostic tooling and tests.
M.parse_tilemap_diag = parse_tilemap_diag
M.build_diag_layer_state = build_diag_layer_state
M.collect_changed_tile_keys = collect_changed_tile_keys

return M
