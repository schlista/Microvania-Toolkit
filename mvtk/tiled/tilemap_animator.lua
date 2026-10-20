--- Tilemap Animator
-- Runtime tile animation system for painted tilemap cells.
--
-- Why this exists:
-- Defold tilemaps do not auto-play Tiled animated tiles at runtime.
-- This module scans authored cells and swaps tile IDs over time.
--
-- Supported definition sources (merged in this order):
--   1) developer/config/tilemap_animations_generated.lua (auto-generated)
--   2) developer/config/tilemap_animations.lua (manual overrides)
--   3) Tiled map/layer custom property "tile_animations"
--   4) options.definitions passed at startup
--
-- Later sources override earlier ones when they target the same
-- layer + seed_tile pair.
--
-- Tiled property format (one entry per line, ';' also supported):
--   map property:
--     layer|seed|frame1,frame2,frame3|fps|mode
--   tile layer property:
--     seed|frame1,frame2,frame3|fps|mode
--
-- Example map property value:
--   ground|401|401,402,403,404|8|loop
--   hazards|560|560,561,562,563|10|pingpong
--   lava|700|700,701,702,703|12|once
--
-- @module tilemap_animator

local Util = require "mvtk.core.util"
local TiledParser = require "mvtk.tiled.tiled_parser"

local M = {}

local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...) -- luacheck: ignore 121
    if _Dbg.tiled and _Dbg.tiled.animator then
        _orig_print(...)
    end
end

local DEFAULT_PROPERTY_KEY = "tile_animations"
local DEFAULT_FPS = 8
local EMPTY_HASH = hash("")

local GeneratedConfigCache = nil
local ManualConfigCache = nil

local function trim(v)
    return Util.trim(v)
end

local function shallow_copy(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for k, v in pairs(src) do
        out[k] = v
    end
    return out
end

local function split_entries(raw)
    local entries = {}
    local text = tostring(raw or "")
    if text == "" then
        return entries
    end
    text = text:gsub("\r", "\n")
    for part in text:gmatch("[^\n;]+") do
        local line = trim(part)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            entries[#entries + 1] = line
        end
    end
    return entries
end

local function parse_int_list(raw)
    local out = {}
    if type(raw) == "table" then
        for _, value in ipairs(raw) do
            local n = tonumber(value)
            if n and n > 0 then
                out[#out + 1] = math.floor(n + 0.5)
            end
        end
        return out
    end
    local text = tostring(raw or "")
    for token in text:gmatch("[^,%s]+") do
        local n = tonumber(token)
        if n and n > 0 then
            out[#out + 1] = math.floor(n + 0.5)
        end
    end
    return out
end

local function parse_number_list(raw)
    local out = {}
    if type(raw) == "table" then
        for _, value in ipairs(raw) do
            local n = tonumber(value)
            if n and n > 0 then
                out[#out + 1] = n
            end
        end
        return out
    end
    local text = tostring(raw or "")
    for token in text:gmatch("[^,%s]+") do
        local n = tonumber(token)
        if n and n > 0 then
            out[#out + 1] = n
        end
    end
    return out
end

local function split_pipe(line)
    local out = {}
    for token in tostring(line or ""):gmatch("[^|]+") do
        out[#out + 1] = trim(token)
    end
    return out
end

local function normalize_mode(mode)
    local m = tostring(mode or ""):lower()
    if m == "pingpong" or m == "ping_pong" then
        return "pingpong"
    end
    if m == "once" or m == "play_once" or m == "once_forward" or m == "oneshot" or m == "one_shot" then
        return "once"
    end
    return "loop"
end

local function build_def_from_tokens(tokens, default_layer, source)
    local layer = nil
    local seed_token = nil
    local frames_token = nil
    local fps_token = nil
    local mode_token = nil

    if default_layer then
        layer = default_layer
        if #tokens >= 4 then
            seed_token = tokens[1]
            frames_token = tokens[2]
            fps_token = tokens[3]
            mode_token = tokens[4]
        elseif #tokens == 3 then
            seed_token = tokens[1]
            frames_token = tokens[2]
            fps_token = tokens[3]
        elseif #tokens == 2 then
            seed_token = tokens[1]
            frames_token = tokens[2]
        elseif #tokens == 1 then
            frames_token = tokens[1]
        end
    else
        if #tokens >= 5 then
            layer = tokens[1]
            seed_token = tokens[2]
            frames_token = tokens[3]
            fps_token = tokens[4]
            mode_token = tokens[5]
        elseif #tokens == 4 then
            layer = tokens[1]
            seed_token = tokens[2]
            frames_token = tokens[3]
            fps_token = tokens[4]
        elseif #tokens == 3 then
            layer = tokens[1]
            seed_token = tokens[2]
            frames_token = tokens[3]
        elseif #tokens == 2 then
            layer = tokens[1]
            frames_token = tokens[2]
        end
    end

    layer = trim(layer)
    if layer == "" then
        return nil, "missing_layer"
    end

    local frames = parse_int_list(frames_token)
    if #frames < 2 then
        return nil, "invalid_frames"
    end

    local seed = tonumber(seed_token)
    if not seed or seed <= 0 then
        seed = frames[1]
    else
        seed = math.floor(seed + 0.5)
    end

    local fps = tonumber(fps_token) or DEFAULT_FPS
    if fps <= 0 then fps = DEFAULT_FPS end

    return {
        layer = layer,
        seed_tile = seed,
        frames = frames,
        fps = fps,
        mode = normalize_mode(mode_token),
        source = source,
        match_any_frame = true,
    }
end

local function parse_property_string(raw, default_layer, source)
    local defs = {}
    for _, line in ipairs(split_entries(raw)) do
        local def, err
        if line:find("|", 1, true) then
            local tokens = split_pipe(line)
            def, err = build_def_from_tokens(tokens, default_layer, source)
        else
            def, err = nil, "missing_separator"
        end
        if def then
            defs[#defs + 1] = def
        else
            print(string.format("[TILEMAP_ANIMATOR] Ignored entry '%s' (%s)", line, tostring(err)))
        end
    end
    return defs
end

local function normalize_definition(raw, source_hint)
    if type(raw) ~= "table" then
        return nil
    end

    local layer = trim(raw.layer or raw.layer_name or "")
    if layer == "" then
        return nil
    end

    local frames = parse_int_list(raw.frames)
    if #frames < 2 then
        return nil
    end

    local seed = tonumber(raw.seed_tile or raw.seed or raw.start_tile)
    if seed and seed > 0 then
        seed = math.floor(seed + 0.5)
    else
        seed = frames[1]
    end

    local fps = tonumber(raw.fps or raw.speed) or DEFAULT_FPS
    if fps <= 0 then fps = DEFAULT_FPS end

    local mode = normalize_mode(raw.mode or raw.playback)
    local match_any_frame = Util.to_bool(raw.match_any_frame, true)
    local frame_durations = nil

    local duration_seconds = parse_number_list(raw.frame_durations or raw.durations)
    if #duration_seconds == #frames then
        frame_durations = duration_seconds
    else
        local duration_ms = parse_number_list(raw.frame_durations_ms or raw.durations_ms)
        if #duration_ms == #frames then
            frame_durations = {}
            for i, value in ipairs(duration_ms) do
                frame_durations[i] = value / 1000
            end
        end
    end

    return {
        layer = layer,
        seed_tile = seed,
        frames = frames,
        fps = fps,
        mode = mode,
        source = raw.source or source_hint,
        match_any_frame = match_any_frame,
        frame_durations = frame_durations,
    }
end

local function collect_tile_layers(layers, out)
    if type(layers) ~= "table" then return end
    for _, layer in ipairs(layers) do
        if type(layer) == "table" then
            if layer.type == "tilelayer" then
                out[#out + 1] = layer
            elseif layer.type == "group" and type(layer.layers) == "table" then
                collect_tile_layers(layer.layers, out)
            end
        end
    end
end

local function get_generated_config()
    if GeneratedConfigCache ~= nil then
        return GeneratedConfigCache
    end
    local cfg = Util.require_config("developer.config.tilemap_animations_generated", nil)
    if type(cfg) == "table" then
        GeneratedConfigCache = cfg
    else
        GeneratedConfigCache = false
    end
    return GeneratedConfigCache
end

local function get_manual_config()
    if ManualConfigCache ~= nil then
        return ManualConfigCache
    end
    local cfg = Util.require_config("developer.config.tilemap_animations", nil)
    if type(cfg) == "table" then
        ManualConfigCache = cfg
    else
        ManualConfigCache = false
    end
    return ManualConfigCache
end

local function append_defs_from_config(defs, cfg, room_id, source_prefix)
    if not cfg then
        return
    end

    local function append_defs(list, source)
        if type(list) ~= "table" then return end
        for _, raw in ipairs(list) do
            local def = normalize_definition(raw, source)
            if def then
                defs[#defs + 1] = def
            end
        end
    end

    append_defs(cfg.defaults, source_prefix .. ":defaults")

    if room_id and cfg.rooms and type(cfg.rooms) == "table" then
        append_defs(cfg.rooms[room_id], source_prefix .. ":rooms." .. room_id)
    end

    if room_id and type(cfg[room_id]) == "table" then
        append_defs(cfg[room_id], source_prefix .. ":" .. room_id)
    end
end

local function defs_from_config(room_id)
    local defs = {}
    append_defs_from_config(defs, get_generated_config(), room_id, "config_generated")
    append_defs_from_config(defs, get_manual_config(), room_id, "config")

    return defs
end

local function defs_from_tiled_map(map, property_key)
    if type(map) ~= "table" then
        return {}
    end

    local key = trim(property_key or DEFAULT_PROPERTY_KEY)
    if key == "" then key = DEFAULT_PROPERTY_KEY end

    local defs = {}

    local map_props = TiledParser.extract_properties(map.properties)
    local map_value = map_props and map_props[key]
    if map_value ~= nil then
        local parsed = parse_property_string(map_value, nil, "tiled:map")
        for _, def in ipairs(parsed) do
            defs[#defs + 1] = def
        end
    end

    local tile_layers = {}
    collect_tile_layers(map.layers, tile_layers)
    for _, layer in ipairs(tile_layers) do
        local layer_props = TiledParser.extract_properties(layer.properties)
        local raw = layer_props and layer_props[key]
        if raw ~= nil then
            local parsed = parse_property_string(raw, layer.name, "tiled:layer:" .. tostring(layer.name))
            for _, def in ipairs(parsed) do
                defs[#defs + 1] = def
            end
        end
    end

    return defs
end

local function build_def_key(def)
    return table.concat({
        tostring(def.layer),
        tostring(def.seed_tile),
        table.concat(def.frames or {}, ","),
        tostring(def.fps),
        tostring(def.mode),
    }, "|")
end

local function build_def_identity(def)
    return table.concat({
        tostring(def.layer),
        tostring(def.seed_tile),
    }, "|")
end

local function collect_candidates(options)
    local order = {}
    local by_identity = {}
    local room_id = options.room_id

    local function register(def)
        if not def then return end
        local identity = build_def_identity(def)
        if by_identity[identity] == nil then
            order[#order + 1] = identity
        end
        by_identity[identity] = def
    end

    if options.use_config ~= false then
        for _, def in ipairs(defs_from_config(room_id)) do
            register(def)
        end
    end

    if options.use_tiled_properties ~= false then
        for _, def in ipairs(defs_from_tiled_map(options.tiled_map, options.property_key)) do
            register(def)
        end
    end

    if type(options.definitions) == "table" then
        for _, raw in ipairs(options.definitions) do
            register(normalize_definition(raw, "runtime"))
        end
    end

    local out = {}
    local unique = {}
    for _, identity in ipairs(order) do
        local def = by_identity[identity]
        local key = build_def_key(def)
        if not unique[key] then
            unique[key] = true
            out[#out + 1] = def
        end
    end
    return out
end

local function resolve_room_id_string(room_id)
    if type(room_id) == "string" then
        return room_id
    end
    local s = Util.normalize_hash_string(room_id, { keep_unknown = true, keep_zero = false })
    if s == nil or s == "" then
        return nil
    end
    return s
end

local function offset_frames(frames, offset)
    if offset == 0 then
        return shallow_copy(frames)
    end

    local out = {}
    for i, id in ipairs(frames or {}) do
        local value = math.floor((tonumber(id) or 0) + 0.5) + offset
        if value <= 0 then
            return nil
        end
        out[i] = value
    end
    return out
end

local function build_runtime_def(def, offset)
    offset = tonumber(offset) or 0

    local seed_tile = math.floor((tonumber(def and def.seed_tile) or 0) + 0.5) + offset
    if seed_tile <= 0 then
        return nil
    end

    local frames = offset_frames(def and def.frames, offset)
    if type(frames) ~= "table" or #frames < 2 then
        return nil
    end

    local out = shallow_copy(def)
    out.seed_tile = seed_tile
    out.frames = frames
    return out
end

local function scan_cells(tilemap_url, layer_hash, min_x, min_y, width, height, def)
    local frame_lookup = {}
    for _, id in ipairs(def.frames) do
        frame_lookup[id] = true
    end

    local cells = {}
    local max_x = min_x + width - 1
    local max_y = min_y + height - 1

    for tx = min_x, max_x do
        for ty = min_y, max_y do
            local tid = tilemap.get_tile(tilemap_url, layer_hash, tx, ty) or 0
            if tid > 0 then
                if tid == def.seed_tile or (def.match_any_frame and frame_lookup[tid]) then
                    cells[#cells + 1] = { x = tx, y = ty }
                end
            end
        end
    end

    return cells
end

local function find_cells(tilemap_url, def)
    local layer_hash = hash(def.layer)
    if layer_hash == EMPTY_HASH then
        return nil, "invalid_layer"
    end

    -- Check layer existence (Create Rooms manifest; Defold cannot list
    -- layers) before touching tiles, to avoid "Could not find layer" errors.
    local ok_tl, TilemapLayers = pcall(require, "mvtk.rooms.tilemap_layers")
    if ok_tl and TilemapLayers then
        local _, lookup = TilemapLayers.for_url(tilemap_url)
        if lookup and not lookup[layer_hash] then
            return nil, "layer_not_found"
        end
    end

    local ok_bounds, min_x, min_y, width, height = pcall(tilemap.get_bounds, tilemap_url, layer_hash)
    if not ok_bounds then
        return nil, "layer_not_found"
    end

    -- Tiled exports, generated config, and Defold tilemap runtime can disagree by 1
    -- depending on whether the tile IDs came from GIDs or tilemap cell values.
    local offsets = { 0, -1, 1 }
    local resolved_def = nil
    local resolved_offset = 0
    local cells = nil

    for _, offset in ipairs(offsets) do
        local runtime_def = build_runtime_def(def, offset)
        if runtime_def then
            local matched_cells = scan_cells(tilemap_url, layer_hash, min_x, min_y, width, height, runtime_def)
            if #matched_cells > 0 then
                resolved_def = runtime_def
                resolved_offset = offset
                cells = matched_cells
                break
            end
        end
    end

    if not cells or #cells == 0 then
        return nil, "seed_not_found"
    end

    return {
        id = build_def_key(resolved_def),
        layer = resolved_def.layer,
        layer_hash = layer_hash,
        seed_tile = resolved_def.seed_tile,
        configured_seed_tile = def.seed_tile,
        tile_id_offset = resolved_offset,
        frames = shallow_copy(resolved_def.frames),
        fps = resolved_def.fps,
        frame_durations = resolved_def.frame_durations and shallow_copy(resolved_def.frame_durations) or nil,
        mode = resolved_def.mode,
        source = resolved_def.source or "unknown",
        cells = cells,
        frame_index = 1,
        elapsed = 0,
        dir = 1,
        completed = false,
    }, nil
end

local function apply_frame(tilemap_url, anim)
    tilemap_url = anim.tilemap_url or tilemap_url
    local tile_id = anim.frames[anim.frame_index]
    if not tile_id or tile_id <= 0 then
        return
    end
    -- Skip animations that previously failed due to out-of-range tile IDs
    if anim._disabled then return end
    for _, cell in ipairs(anim.cells) do
        local ok = pcall(tilemap.set_tile, tilemap_url, anim.layer_hash, cell.x, cell.y, tile_id)
        if not ok and not anim._disabled then
            anim._disabled = true
            print(string.format("[TILEMAP_ANIMATOR] tile_id %d out of range for layer %s - disabling animation",
                tile_id, tostring(anim.layer or "?")))
            return
        end
    end
end

local function advance(anim)
    local count = #anim.frames
    if count <= 1 then
        return false
    end

    local previous = anim.frame_index

    if anim.mode == "once" then
        if anim.frame_index >= count then
            anim.completed = true
            return false
        end
        anim.frame_index = anim.frame_index + 1
        if anim.frame_index >= count then
            anim.frame_index = count
            anim.completed = true
        end
    elseif anim.mode == "pingpong" then
        local next_index = anim.frame_index + anim.dir
        if next_index > count then
            anim.dir = -1
            next_index = count - 1
            if next_index < 1 then next_index = 1 end
        elseif next_index < 1 then
            anim.dir = 1
            next_index = 2
            if next_index > count then next_index = count end
        end
        anim.frame_index = next_index
    else
        anim.frame_index = anim.frame_index + 1
        if anim.frame_index > count then
            anim.frame_index = 1
        end
    end

    return anim.frame_index ~= previous
end

local function current_step(anim)
    local durations = anim and anim.frame_durations
    if type(durations) == "table" then
        local value = tonumber(durations[anim.frame_index or 1])
        if value and value > 0 then
            return value
        end
    end
    return 1 / ((anim and anim.fps and anim.fps > 0) and anim.fps or DEFAULT_FPS)
end

--- Start tilemap animation state.
-- @param options table:
--   tilemap_url (required)
--   layer_urls (optional layer-name -> URL overrides for baked parallax tiles)
--   room_id (string/hash, optional)
--   tiled_map (table from tiled_parser.load, optional)
--   definitions (array of runtime definitions, optional)
--   use_config (bool, default true)
--   use_tiled_properties (bool, default true)
--   property_key (string, default "tile_animations")
-- @return state table (pass to update/stop)
function M.start(options)
    options = options or {}
    local state = {
        running = false,
        tilemap_url = options.tilemap_url,
        room_id = resolve_room_id_string(options.room_id),
        definitions = {},
        stats = {
            candidate_defs = 0,
            active_defs = 0,
            animated_cells = 0,
        },
    }

    if not state.tilemap_url then
        print("[TILEMAP_ANIMATOR] No tilemap_url; animations disabled")
        return state
    end

    local candidates = collect_candidates({
        room_id = state.room_id,
        tiled_map = options.tiled_map,
        definitions = options.definitions,
        use_config = options.use_config,
        use_tiled_properties = options.use_tiled_properties,
        property_key = options.property_key,
    })
    state.stats.candidate_defs = #candidates

    local total_cells = 0
    for _, def in ipairs(candidates) do
        local target = (options.layer_urls or {})[def.layer] or state.tilemap_url
        local anim, err = find_cells(target, def)
        if anim then
            anim.tilemap_url = target
            state.definitions[#state.definitions + 1] = anim
            total_cells = total_cells + #anim.cells
            apply_frame(state.tilemap_url, anim)
            if (anim.tile_id_offset or 0) ~= 0 then
                print(string.format("[TILEMAP_ANIMATOR] Resolved tile ID offset %+d (layer=%s configured_seed=%s runtime_seed=%s source=%s)",
                    anim.tile_id_offset,
                    tostring(anim.layer),
                    tostring(anim.configured_seed_tile),
                    tostring(anim.seed_tile),
                    tostring(anim.source)))
            end
            print(string.format("[TILEMAP_ANIMATOR] Enabled %s (layer=%s cells=%d source=%s)",
                tostring(anim.id), anim.layer, #anim.cells, tostring(anim.source)))
        else
            print(string.format("[TILEMAP_ANIMATOR] Skipped def layer=%s seed=%s (%s)",
                tostring(def.layer), tostring(def.seed_tile), tostring(err)))
        end
    end

    state.stats.active_defs = #state.definitions
    state.stats.animated_cells = total_cells
    state.running = #state.definitions > 0

    if state.running then
        print(string.format("[TILEMAP_ANIMATOR] Started (%d defs, %d cells)",
            state.stats.active_defs, state.stats.animated_cells))
    else
        print(string.format("[TILEMAP_ANIMATOR] No active tile animations found (room_id=%s candidates=%d generated_config=%s manual_config=%s)",
            tostring(state.room_id),
            state.stats.candidate_defs,
            tostring(get_generated_config() and "loaded" or "FAILED"),
            tostring(get_manual_config() and "loaded" or "none")))
    end

    return state
end

--- Update tile animations.
-- @param state State from start()
-- @param dt Delta time
function M.update(state, dt)
    if type(state) ~= "table" or not state.running then
        return
    end

    local delta = tonumber(dt) or 0
    if delta <= 0 then
        return
    end

    for _, anim in ipairs(state.definitions) do
        if not anim.completed then
            anim.elapsed = anim.elapsed + delta
            local changed = false

            while anim.elapsed >= current_step(anim) do
                local step = current_step(anim)
                anim.elapsed = anim.elapsed - step
                if advance(anim) then
                    changed = true
                end
                if anim.completed then
                    anim.elapsed = 0
                    break
                end
            end

            if changed then
                apply_frame(state.tilemap_url, anim)
            end
        end
    end
end

--- Stop tile animations.
-- @param state State from start()
-- @param restore_first_frame Optional bool; reset to first frame on stop
function M.stop(state, restore_first_frame)
    if type(state) ~= "table" then
        return
    end
    if restore_first_frame then
        for _, anim in ipairs(state.definitions or {}) do
            anim.frame_index = 1
            apply_frame(state.tilemap_url, anim)
        end
    end
    state.running = false
    state.definitions = {}
    state.stats.active_defs = 0
    state.stats.animated_cells = 0
end

--- Return a lightweight stats table for debug UIs/logging.
-- @param state State from start()
-- @return stats table
function M.get_stats(state)
    if type(state) ~= "table" then
        return {
            running = false,
            candidate_defs = 0,
            active_defs = 0,
            animated_cells = 0,
        }
    end
    return {
        running = state.running == true,
        candidate_defs = state.stats and state.stats.candidate_defs or 0,
        active_defs = state.stats and state.stats.active_defs or 0,
        animated_cells = state.stats and state.stats.animated_cells or 0,
    }
end

return M
