-- Pure helpers for Project > Sync Enemy Art.
--
-- This module intentionally has no Defold editor API or filesystem dependencies.
-- CANONICAL_STATES must stay in lockstep with the enemy_animations enum
-- (custom type id 56). STATE_TIMING defines animation playback/fps without
-- relying on base placeholder animations in developer/assets/atlas/enemy.atlas.

local ProtoUtils = require "mvtk.editor.proto_utils"
local Util = require "mvtk.core.util"
local M = {}

M.DEFAULT_SKIN = "default"
M.GENERATED_SPRITE_DIR = "developer/assets/enemies/generated"
M.GENERATED_PREFAB_DIR = "developer/game/prefabs/generated"
M.BEGIN_MARKER = "# === BEGIN GENERATED ENEMY SKINS (Sync Enemy Art - do not edit) ==="
M.END_MARKER = "# === END GENERATED ENEMY SKINS ==="

M.CANONICAL_STATES = {
    "idle",
    "walk",
    "run",
    "jump",
    "fall",
    "land",
    "fly",
    "fly_idle",
    "hover",
    "dive",
    "patrol",
    "alert",
    "chase",
    "search",
    "return",
    "attack",
    "attack_alt",
    "ranged_attack",
    "charge",
    "charge_windup",
    "slam",
    "block",
    "spawn",
    "hurt",
    "stun",
    "die",
    "death",
}

M.STATE_TIMING = {
    idle = { playback = "PLAYBACK_LOOP_FORWARD", fps = 6 },
    walk = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    run = { playback = "PLAYBACK_LOOP_FORWARD", fps = 10 },
    jump = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    fall = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    land = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    fly = { playback = "PLAYBACK_LOOP_FORWARD", fps = 10 },
    fly_idle = { playback = "PLAYBACK_LOOP_FORWARD", fps = 6 },
    hover = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    dive = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    patrol = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    alert = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    chase = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    search = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    ["return"] = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    attack = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    attack_alt = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    ranged_attack = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    charge = { playback = "PLAYBACK_ONCE_FORWARD", fps = 14 },
    charge_windup = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    slam = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    block = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    spawn = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    hurt = { playback = "PLAYBACK_ONCE_FORWARD", fps = 12 },
    stun = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 },
    die = { playback = "PLAYBACK_ONCE_FORWARD", fps = 10 },
    death = { playback = "PLAYBACK_ONCE_FORWARD", fps = 10 },
}

local DEFAULT_STATE_TIMING = { playback = "PLAYBACK_LOOP_FORWARD", fps = 8 }

local CANONICAL_SET = {}
for _, state in ipairs(M.CANONICAL_STATES) do
    CANONICAL_SET[state] = true
end

local LONGEST_STATES = {}
for _, state in ipairs(M.CANONICAL_STATES) do
    LONGEST_STATES[#LONGEST_STATES + 1] = state
end
table.sort(LONGEST_STATES, function(a, b)
    if #a ~= #b then return #a > #b end
    return a < b
end)

local function detect_newline(text)
    if type(text) == "string" and text:find("\r\n", 1, true) then
        return "\r\n"
    end
    return "\n"
end

local function basename(path)
    path = tostring(path or "")
    return path:match("([^/\\]+)$") or path
end

local function sorted_keys(set)
    local out = {}
    for key in pairs(set or {}) do
        out[#out + 1] = key
    end
    table.sort(out)
    return out
end

local function manifest_skins(manifest)
    if type(manifest) ~= "table" then
        return {}
    end
    if type(manifest.skins) == "table" then
        return manifest.skins
    end
    return manifest
end

local function state_order_map()
    local order = {}
    for i, state in ipairs(M.CANONICAL_STATES) do
        order[state] = i
    end
    return order
end

local STATE_ORDER = state_order_map()

local function escape_lua_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    return value
end

local function escape_json_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    return '"' .. value .. '"'
end

local escape_proto_string = ProtoUtils.proto_escape

local function skin_timing_for_state(state, base_meta)
    if type(base_meta) == "table" and type(base_meta[state]) == "table" then
        return base_meta[state]
    end
    return M.STATE_TIMING[state] or DEFAULT_STATE_TIMING
end

local function line_indent_before(text, pos)
    local before = text:sub(1, pos)
    local line_start = before:match(".*\n()") or 1
    return text:sub(line_start, pos - 1):match("^([ \t]*)") or ""
end

local function find_matching_char(text, open_pos, open_char, close_char)
    local depth = 1
    local i = open_pos + 1
    local quote = nil
    while i <= #text do
        local ch = text:sub(i, i)
        if quote then
            if ch == "\\" then
                i = i + 2
            elseif ch == quote then
                quote = nil
                i = i + 1
            else
                i = i + 1
            end
        else
            local pair = text:sub(i, i + 1)
            if pair == "--" then
                local nl = text:find("\n", i + 2, true)
                i = nl and (nl + 1) or (#text + 1)
            elseif ch == '"' or ch == "'" then
                quote = ch
                i = i + 1
            elseif ch == open_char then
                depth = depth + 1
                i = i + 1
            elseif ch == close_char then
                depth = depth - 1
                if depth == 0 then
                    return i
                end
                i = i + 1
            else
                i = i + 1
            end
        end
    end
    return nil
end

local function strip_generated_region(text)
    text = tostring(text or "")
    local begin_pos = text:find(M.BEGIN_MARKER, 1, true)
    if not begin_pos then
        return text
    end
    local _, end_pos = text:find(M.END_MARKER, begin_pos, true)
    if not end_pos then
        return text
    end
    local after = end_pos + 1
    if text:sub(after, after + 1) == "\r\n" then
        after = after + 2
    elseif text:sub(after, after) == "\n" then
        after = after + 1
    end
    return text:sub(1, begin_pos - 1) .. text:sub(after)
end

local function sorted_skins(skins)
    local out = {}
    for _, skin in ipairs(skins or {}) do
        if type(skin) == "table" and skin.skin_id and type(skin.states) == "table" then
            out[#out + 1] = skin
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.skin_id) < tostring(b.skin_id)
    end)
    return out
end

local function sorted_skin_ids_from_skins(skins)
    local ids = {}
    for _, skin in ipairs(skins or {}) do
        if type(skin) == "table" and skin.skin_id and skin.skin_id ~= "" then
            ids[#ids + 1] = tostring(skin.skin_id)
        else
            ids[#ids + 1] = tostring(skin)
        end
    end
    table.sort(ids)
    return ids
end

local function sorted_states_for_skin(skin)
    local states = {}
    for state in pairs((skin and skin.states) or {}) do
        states[#states + 1] = state
    end
    table.sort(states, function(a, b)
        local ao = STATE_ORDER[a] or 9999
        local bo = STATE_ORDER[b] or 9999
        if ao ~= bo then return ao < bo end
        return a < b
    end)
    return states
end

function M.sanitize_skin_id(folder_name)
    local id = basename(folder_name):lower()
    id = id:gsub("[%s%-]+", "_")
    id = id:gsub("[^a-z0-9_]", "")
    id = id:gsub("_+", "_")
    id = id:gsub("^_+", "")
    id = id:gsub("_+$", "")
    if id == "" then
        return nil, "sanitized skin id is empty"
    end
    if id == "none" then
        return nil, "skin id 'none' is reserved"
    end
    return id
end

function M.normalize_skin_id(value)
    local text = Util.normalize_hash_string(value)
    if not text or text:lower() == "none" then return nil end
    return text
end

function M.resolve_active_skin_id(requested, manifest, default_skin)
    local requested_id = M.normalize_skin_id(requested)
    local skins = manifest_skins(manifest)
    if requested_id and skins[requested_id] ~= nil then
        return requested_id, requested_id, false
    end

    local fallback = M.normalize_skin_id(default_skin) or M.DEFAULT_SKIN
    if fallback and skins[fallback] ~= nil then
        return fallback, requested_id, requested_id ~= nil
    end

    return nil, requested_id, requested_id ~= nil
end

local function match_skin_filename(filename)
    local lower = filename:lower()
    if not lower:match("%.png$") then
        return nil, nil, "only PNG files are supported"
    end
    local stem = lower:gsub("%.png$", "")
    for _, state in ipairs(LONGEST_STATES) do
        if stem == state then
            return state, 0, nil
        end
        local index = stem:match("^" .. state .. "_(%d+)$")
        if index then
            return state, tonumber(index) or 0, nil
        end
    end
    return nil, nil, "unknown enemy animation state"
end

function M.group_skin_files(skin_id, files)
    local groups = {}
    local issues = {}
    local valid_states = table.concat(M.CANONICAL_STATES, ", ")

    for _, file in ipairs(files or {}) do
        local filename = basename(type(file) == "table" and (file.filename or file.file or file.path) or file)
        local state, index, err = match_skin_filename(filename)
        if not state then
            issues[#issues + 1] = {
                type = err == "unknown enemy animation state" and "unknown_state" or "unsupported_extension",
                skin_id = skin_id,
                filename = filename,
                reason = err,
                valid_states = valid_states,
            }
        else
            groups[state] = groups[state] or {}
            groups[state][#groups[state] + 1] = {
                filename = filename,
                index = index or 0,
            }
        end
    end

    local states = {}
    for state, frames in pairs(groups) do
        table.sort(frames, function(a, b)
            if a.index ~= b.index then return a.index < b.index end
            local al = a.filename:lower()
            local bl = b.filename:lower()
            if al ~= bl then return al < bl end
            return a.filename < b.filename
        end)
        states[state] = {}
        for _, frame in ipairs(frames) do
            states[state][#states[state] + 1] = frame.filename
        end
    end

    if next(states) ~= nil and not states.idle then
        issues[#issues + 1] = {
            type = "missing_idle",
            skin_id = skin_id,
            reason = "skin has no idle.png or idle_N.png frame",
        }
    end

    return {
        skin_id = skin_id,
        states = states,
        issues = issues,
    }
end

function M.parse_base_anim_meta(atlas_text)
    local text = strip_generated_region(atlas_text)
    local meta = {}
    local pos = 1
    while true do
        local start_pos, open_pos = text:find("animations%s*{", pos)
        if not start_pos then
            break
        end
        local close_pos = find_matching_char(text, open_pos, "{", "}")
        if not close_pos then
            break
        end
        local block = text:sub(start_pos, close_pos)
        local id = block:match('id:%s*"([^"]+)"')
        if id and not id:find("__", 1, true) then
            meta[id] = {
                playback = block:match("playback:%s*([%w_]+)") or "PLAYBACK_LOOP_FORWARD",
                fps = tonumber(block:match("fps:%s*([%d%.]+)")) or 8,
            }
        end
        pos = close_pos + 1
    end
    return meta
end

local function generate_enemy_skin_atlas_region(skins, base_meta, newline)
    local lines = { M.BEGIN_MARKER }
    for _, skin in ipairs(sorted_skins(skins)) do
        local folder_name = skin.folder_name or skin.skin_id
        for _, state in ipairs(sorted_states_for_skin(skin)) do
            local frames = skin.states[state] or {}
            if #frames > 0 then
                local meta = skin_timing_for_state(state, base_meta)
                lines[#lines + 1] = "animations {"
                lines[#lines + 1] = string.format('  id: "%s__%s"', escape_proto_string(skin.skin_id), escape_proto_string(state))
                for _, frame in ipairs(frames) do
                    lines[#lines + 1] = string.format(
                        '  images { image: "/developer/assets/enemies/%s/%s" }',
                        escape_proto_string(folder_name),
                        escape_proto_string(frame)
                    )
                end
                lines[#lines + 1] = string.format("  playback: %s", tostring(meta.playback or "PLAYBACK_LOOP_FORWARD"))
                lines[#lines + 1] = string.format("  fps: %s", tostring(meta.fps or 8))
                lines[#lines + 1] = "  flip_horizontal: 0"
                lines[#lines + 1] = "  flip_vertical: 0"
                lines[#lines + 1] = "}"
            end
        end
    end
    lines[#lines + 1] = M.END_MARKER
    return table.concat(lines, newline) .. newline
end

function M.rewrite_enemy_atlas(atlas_text, skins)
    atlas_text = tostring(atlas_text or "")
    local newline = detect_newline(atlas_text)
    local base_meta = M.parse_base_anim_meta(atlas_text)
    local region = generate_enemy_skin_atlas_region(skins, base_meta, newline)

    local begin_pos = atlas_text:find(M.BEGIN_MARKER, 1, true)
    if begin_pos then
        local _, end_pos = atlas_text:find(M.END_MARKER, begin_pos, true)
        if not end_pos then
            return nil, "Found enemy skin atlas begin marker without end marker"
        end
        local after = end_pos + 1
        if atlas_text:sub(after, after + 1) == "\r\n" then
            after = after + 2
        elseif atlas_text:sub(after, after) == "\n" then
            after = after + 1
        end
        return atlas_text:sub(1, begin_pos - 1) .. region .. atlas_text:sub(after)
    end

    local prefix = atlas_text
    if prefix ~= "" and not prefix:match("\n$") then
        prefix = prefix .. newline
    end
    if prefix ~= "" and not prefix:match(newline .. "$") then
        prefix = prefix .. newline
    end
    return prefix .. region
end

local function enum_values_region(json_text, enum_name)
    local name_pattern = '"name"%s*:%s*"' .. enum_name .. '"'
    local name_start, name_end = json_text:find(name_pattern)
    if not name_start then
        return nil, "Could not find " .. enum_name .. " enum"
    end
    local _, open_pos = json_text:find('"values"%s*:%s*%[', name_end + 1)
    if not open_pos then
        return nil, "Could not find " .. enum_name .. " values array"
    end
    local close_pos = find_matching_char(json_text, open_pos, "[", "]")
    if not close_pos then
        return nil, "Could not find closing bracket for " .. enum_name .. " values"
    end
    return {
        open_pos = open_pos,
        close_pos = close_pos,
    }
end

function M.rewrite_enum_values(json_text, enum_name, values)
    local region, err = enum_values_region(json_text, enum_name)
    if not region then
        return nil, err
    end

    local newline = detect_newline(json_text)
    local body = json_text:sub(region.open_pos + 1, region.close_pos - 1)
    local value_indent = body:match("\n([ \t]*)\"")
    local close_indent = line_indent_before(json_text, region.close_pos)
    if not value_indent then
        value_indent = close_indent .. "    "
    end

    local lines = {}
    for i, id in ipairs(values or {}) do
        local comma = (i < #(values or {})) and "," or ""
        lines[#lines + 1] = value_indent .. escape_json_string(id) .. comma
    end

    local replacement
    if #lines > 0 then
        replacement = newline .. table.concat(lines, newline) .. newline .. close_indent
    else
        replacement = newline .. close_indent
    end

    return json_text:sub(1, region.open_pos) .. replacement .. json_text:sub(region.close_pos)
end

function M.rewrite_enemy_skins_enum(json_text, skins)
    local ids = { "none" }
    for _, id in ipairs(sorted_skin_ids_from_skins(skins)) do
        if id ~= "" and id ~= "none" then
            ids[#ids + 1] = id
        end
    end
    return M.rewrite_enum_values(json_text, "enemy_skins", ids)
end

function M.parse_enum_values(json_text, enum_name)
    local region, err = enum_values_region(json_text, enum_name)
    if not region then
        return nil, err
    end
    local body = json_text:sub(region.open_pos + 1, region.close_pos - 1)
    local values = {}
    for value in body:gmatch('"([^"]*)"') do
        values[#values + 1] = value
    end
    return values
end

function M.parse_enemy_skins_enum_values(json_text)
    return M.parse_enum_values(json_text, "enemy_skins")
end

function M.generate_skins_manifest(skins)
    local sorted = sorted_skins(skins)
    local lines = {
        "-- GENERATED by Sync Enemy Art. Do not edit.",
        "return {",
        "    skins = {",
    }
    for _, skin in ipairs(sorted) do
        local state_parts = {}
        for _, state in ipairs(sorted_states_for_skin(skin)) do
            state_parts[#state_parts + 1] = string.format("%s = true", state)
        end
        lines[#lines + 1] = string.format('        %s = { states = { %s } },',
            skin.skin_id,
            table.concat(state_parts, ", "))
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

function M.generated_skin_sprite_path(skin_id)
    return string.format("%s/%s.sprite", M.GENERATED_SPRITE_DIR, tostring(skin_id or ""))
end

function M.generated_enemy_prefab_path(skin_id)
    return string.format("%s/enemy_%s.go", M.GENERATED_PREFAB_DIR, tostring(skin_id or ""))
end

function M.generate_skin_sprite(skin_id)
    local anim = escape_proto_string(tostring(skin_id or "") .. "__idle")
    return table.concat({
        'tile_set: "/developer/assets/atlas/enemy.atlas"',
        string.format('default_animation: "%s"', anim),
        'material: "/builtins/materials/sprite.material"',
        "blend_mode: BLEND_MODE_ALPHA",
        "",
    }, "\n")
end

-- Protobuf decimal text built from integers: the editor's LuaJ ignores
-- string.format precision such as %.3f.
local function proto_decimal(value)
    local thousandths = math.floor(math.abs(value) * 1000 + 0.5)
    return string.format("%s%d.%03d", value < 0 and "-" or "",
        math.floor(thousandths / 1000), thousandths % 1000)
end

-- opts.enemy_z: sprite z offset (render_settings.enemy_z). Room tile layers
-- bake at about 0.0007-0.0009, so a sprite at 0 hides behind a painted
-- background layer.
function M.generate_enemy_prefab_go(skin_id, opts)
    local sprite_path = "/" .. M.generated_skin_sprite_path(skin_id)
    local enemy_z = tonumber(opts and opts.enemy_z) or 0
    local sprite_position = enemy_z ~= 0
        and table.concat({ "  position {", "    z: " .. proto_decimal(enemy_z), "  }", "" }, "\n")
        or ""
    local lines = {
        "components {",
        '  id: "enemy"',
        '  component: "/mvtk/enemies/enemy.script"',
        "}",
        "components {",
        '  id: "anim"',
        '  component: "/mvtk/animation/animation_controller.script"',
        "  properties {",
        '    id: "default_state"',
        string.format('    value: "%s"', escape_proto_string(tostring(skin_id or "") .. "__idle")),
        '    type: PROPERTY_TYPE_TEXT',
        "  }",
        "  properties {",
        '    id: "sprite_atlas"',
        '    value: "/developer/assets/atlas/enemy.atlas"',
        '    type: PROPERTY_TYPE_TEXT',
        "  }",
        "}",
        "components {",
        '  id: "sprite"',
        string.format('  component: "%s"', escape_proto_string(sprite_path)),
        sprite_position .. "}",
        "components {",
        '  id: "co"',
        '  component: "/developer/game/enemies/collisionobject.collisionobject"',
        "}",
        "embedded_components {",
        '  id: "loot_factory"',
        '  type: "factory"',
        '  data: "prototype: \\"/developer/game/prefabs/loot_coin.go\\"\\n"',
        '  ""',
        "}",
        "",
    }
    return table.concat(lines, "\n")
end

function M.generate_skin_artifact_writes(skins, opts)
    local writes = {}
    for _, skin in ipairs(sorted_skins(skins)) do
        local skin_id = skin.skin_id
        writes[#writes + 1] = {
            path = M.generated_skin_sprite_path(skin_id),
            text = M.generate_skin_sprite(skin_id),
            kind = "sprite",
            skin_id = skin_id,
        }
        writes[#writes + 1] = {
            path = M.generated_enemy_prefab_path(skin_id),
            text = M.generate_enemy_prefab_go(skin_id, opts),
            kind = "prefab",
            skin_id = skin_id,
        }
    end
    return writes
end

function M.parse_generated_atlas_ids(atlas_text)
    atlas_text = tostring(atlas_text or "")
    local begin_pos = atlas_text:find(M.BEGIN_MARKER, 1, true)
    if not begin_pos then
        return {}
    end
    local _, end_pos = atlas_text:find(M.END_MARKER, begin_pos, true)
    if not end_pos then
        return {}
    end
    local region = atlas_text:sub(begin_pos, end_pos)
    local ids = {}
    for id in region:gmatch('id:%s*"([^"]+)"') do
        ids[id] = true
    end
    return ids
end

function M.sorted_skin_ids(skins)
    return sorted_skin_ids_from_skins(skins)
end

function M.skin_state_count(skin)
    local count = 0
    for _, frames in pairs((skin and skin.states) or {}) do
        if type(frames) == "table" and #frames > 0 then
            count = count + 1
        end
    end
    return count
end

function M.skin_frame_count(skin)
    local count = 0
    for _, frames in pairs((skin and skin.states) or {}) do
        if type(frames) == "table" then
            count = count + #frames
        end
    end
    return count
end

function M.skin_state_names(skin)
    return sorted_states_for_skin(skin)
end

function M.is_canonical_state(state)
    return CANONICAL_SET[state] == true
end

local function byte_at(data, index)
    local b = data and data:byte(index)
    return b or 0
end

local function read_u32_be(data, index)
    return byte_at(data, index) * 16777216
        + byte_at(data, index + 1) * 65536
        + byte_at(data, index + 2) * 256
        + byte_at(data, index + 3)
end

function M.png_dimensions_from_bytes(data)
    if type(data) ~= "string" or #data < 24 then
        return nil, nil, "not enough PNG data"
    end
    if data:sub(1, 8) ~= "\137PNG\r\n\026\n" then
        return nil, nil, "missing PNG signature"
    end
    if data:sub(13, 16) ~= "IHDR" then
        return nil, nil, "missing PNG IHDR"
    end
    local width = read_u32_be(data, 17)
    local height = read_u32_be(data, 21)
    if width <= 0 or height <= 0 then
        return nil, nil, "invalid PNG dimensions"
    end
    return width, height, nil
end

function M.sorted_skin_keys_from_manifest(manifest)
    local skins = manifest and manifest.skins or nil
    if type(skins) ~= "table" then
        return {}
    end
    return sorted_keys(skins)
end

return M
