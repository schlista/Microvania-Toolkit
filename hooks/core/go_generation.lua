-- hooks/core/go_generation.lua
--
-- Generated Defold .go helpers used by editor-time room generation. The module
-- keeps prefab sizing and collision-shape patching logic out of the core hook
-- coordinator while preserving the existing shared hook API.

local proto_utils = require("mvtk.editor.proto_utils")

local M = {}

local CollisionBox = nil

local config = {
    info = function() end,
    get_png_dimensions = nil,
    gen_tile_collision = nil,
    gen_object_collision = nil,
}

local CONFIG_KEYS = {
    info = true,
    get_png_dimensions = true,
    gen_tile_collision = true,
    gen_object_collision = true,
}

function M.configure(deps)
    deps = deps or {}
    if deps.collision_box ~= nil then CollisionBox = deps.collision_box end
    for key, value in pairs(deps) do
        if CONFIG_KEYS[key] then
            config[key] = value
        end
    end
end

local fmt_num = proto_utils.fmt_num
local split_proto_lines = proto_utils.split_proto_lines
local brace_delta = proto_utils.brace_delta

local function info(msg)
    return (config.info or function() end)(msg)
end

local function get_png_dimensions(...)
    assert(config.get_png_dimensions, "hooks.core.go_generation requires get_png_dimensions")
    return config.get_png_dimensions(...)
end

local LEVEL_GO_TEMPLATE = [[components {
  id: "tilemap"
  component: "%s"
}
embedded_components {
  id: "collisionobject"
  type: "collisionobject"
  data: "collision_shape: \"%s\"\n"
  "type: COLLISION_OBJECT_TYPE_STATIC\n"
  "mass: 0.0\n"
  "friction: 0.1\n"
  "restitution: 0.5\n"
  "group: \"\"\n"
  "mask: \"player\"\n"
  "mask: \"enemy\"\n"
  "mask: \"world\"\n"
  ""
}
]]

local function sanitize_collision_group_text(content)
    local cleaned, count_ground = content:gsub('"group: \\\\"ground\\\\"\\n"', '"group: \\\\"\\\\"\\n"')
    local count_solid
    cleaned, count_solid = cleaned:gsub('"group: \\\\"solid\\\\"\\n"', '"group: \\\\"\\\\"\\n"')
    return cleaned
end

local function gen_level_collision_blocks(rid)
    -- Per-tile collision comes from the Tile Collision Editor; object collision
    -- comes from Solid Box/Slope templates. They must not share the tilemap GO:
    -- tilemap.set_tile() broadcasts tile-grid hull updates to every collision
    -- object on that GO, while these use ordinary convex shapes.
    local extra_blocks = {}
    if config.gen_tile_collision then
        local ok, extra = pcall(config.gen_tile_collision, rid)
        if ok and type(extra) == "string" and extra ~= "" then
            extra_blocks[#extra_blocks + 1] = extra
        end
    end
    if config.gen_object_collision then
        local ok, extra = pcall(config.gen_object_collision, rid)
        if ok and type(extra) == "string" and extra ~= "" then
            extra_blocks[#extra_blocks + 1] = extra
        end
    end
    return table.concat(extra_blocks, "")
end

local function gen_level_go(rid, tilemap_resource)
    local tile = tilemap_resource or string.format("/developer/assets/tiled/maps/%s.tilemap", rid)
    -- Keep the tilemap and its tile-grid-shaped collision object together.
    return string.format(LEVEL_GO_TEMPLATE, tile, tile)
end

local function gen_level_tilecol_go(rid)
    local blocks = gen_level_collision_blocks(rid)
    if blocks ~= "" then
        return blocks
    end

    -- A collection prototype must stay valid even when a room has no convex
    -- collision objects. This inert component lets the collection consistently
    -- instance the sibling without adding a collision shape to the tilemap GO.
    return table.concat({
        "components {",
        "  id: \"anchor\"",
        "  component: \"/developer/rooms/prefabs/empty.script\"",
        "}",
        "",
    }, "\n")
end

-- Generate a game object with embedded sprite components for background images
local function gen_backgrounds_go(rid, sprite_components)
    local rows = {}
    local background_material = "/mvtk/tiled/materials/parallax_clip_background.material"
    local foreground_material = "/mvtk/tiled/materials/parallax_clip_foreground.material"
    
    for _, comp in ipairs(sprite_components) do
        local sx = tonumber(comp.scale_x) or 1.0
        local sy = tonumber(comp.scale_y) or 1.0
        local material_path = comp.material_path
        if not material_path or material_path == "" then
            if (tonumber(comp.pos_z) or 0) > 0 then
                material_path = foreground_material
            else
                material_path = background_material
            end
        end
        if comp.flip_horizontal then
            sx = -sx
        end
        if comp.flip_vertical then
            sy = -sy
        end

        rows[#rows + 1] = 'embedded_components {'
        rows[#rows + 1] = string.format('  id: "%s"', comp.id)
        rows[#rows + 1] = '  type: "sprite"'
        rows[#rows + 1] = string.format('  data: "tile_set: \\"%s\\"\\n"', comp.atlas_path)
        rows[#rows + 1] = string.format('  "default_animation: \\"%s\\"\\n"', comp.animation_name or "default")
        rows[#rows + 1] = string.format('  "material: \\"%s\\"\\n"', material_path)
        rows[#rows + 1] = '  "blend_mode: BLEND_MODE_ALPHA\\n"'
        rows[#rows + 1] = '  ""'
        rows[#rows + 1] = '  position {'
        rows[#rows + 1] = '    x: ' .. fmt_num(comp.pos_x)
        rows[#rows + 1] = '    y: ' .. fmt_num(comp.pos_y)
        rows[#rows + 1] = '    z: ' .. fmt_num(comp.pos_z)
        rows[#rows + 1] = '  }'
        if math.abs(sx - 1.0) > 0.0001 or math.abs(sy - 1.0) > 0.0001 then
            rows[#rows + 1] = '  scale {'
            rows[#rows + 1] = '    x: ' .. fmt_num(sx)
            rows[#rows + 1] = '    y: ' .. fmt_num(sy)
            rows[#rows + 1] = '    z: 1.0'
            rows[#rows + 1] = '  }'
        end
        rows[#rows + 1] = '}'
        
        info(string.format("  - Background sprite: #%s (tile_set: %s, animation: %s, parallax: %.2f)", 
            comp.id, comp.atlas_path, comp.animation_name or "default", comp.parallaxx))
    end
    
    rows[#rows + 1] = ''
    return table.concat(rows, '\n')
end

local function gen_pushable_block_go(width, height, chunk_tilemap_component, chunk_baked, chunk_offset_x, chunk_offset_y, mass)
    local half_w, half_h, w, h
    if CollisionBox and CollisionBox.full_to_half_extents then
        half_w, half_h, w, h = CollisionBox.full_to_half_extents(width, height, 128, 128)
    else
        w = tonumber(width) or 128
        h = tonumber(height) or 128
        if w <= 0 then w = 128 end
        if h <= 0 then h = 128 end
        half_w = w * 0.5
        half_h = h * 0.5
    end

    local sprite_w, sprite_h = get_png_dimensions("developer/assets/atlas/props_base.png")
    if not sprite_w or sprite_w <= 0 then sprite_w = 128 end
    if not sprite_h or sprite_h <= 0 then sprite_h = 128 end
    local sx = w / sprite_w
    local sy = h / sprite_h

    local chunk_component = chunk_tilemap_component or "/developer/game/prefabs/pushable_tile_chunk.tilemap"
    local baked_value = (chunk_baked == true) and "true" or "false"
    local offset_x = tonumber(chunk_offset_x) or 0
    local offset_y = tonumber(chunk_offset_y) or 0

    local rows = {
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/pushable_block.script\"",
        "  properties {",
        "    id: \"block_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"room_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"reset_on_room_load\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "  properties {",
        "    id: \"push_force\"",
        "    value: \"2200.0\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"min_force_scale\"",
        "    value: \"0.35\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"max_force_scale\"",
        "    value: \"1.5\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"gravity_scale\"",
        "    value: \"1.0\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"mass\"",
        "    value: \"" .. fmt_num(tonumber(mass) or 1.0) .. "\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"move_embedded_tiles\"",
        "    value: \"true\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "  properties {",
        "    id: \"capture_width\"",
        "    value: \"" .. fmt_num(w) .. "\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"capture_height\"",
        "    value: \"" .. fmt_num(h) .. "\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"debug_tile_chunk\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "  properties {",
        "    id: \"chunk_baked\"",
        "    value: \"" .. baked_value .. "\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "}",
        "components {",
        "  id: \"chunk\"",
        "  component: \"" .. chunk_component .. "\"",
        "  position {",
        "    x: " .. fmt_num(offset_x),
        "    y: " .. fmt_num(offset_y),
        "    z: 0.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"collision_shape: \\\"\\\"\\n\"",
        "  \"type: COLLISION_OBJECT_TYPE_KINEMATIC\\n\"",
        -- Defold refuses a kinematic body with a positive mass ("Invalid mass")
        -- and the whole room fails to spawn; the authored mass is a script property.
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.6\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"world\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"mask: \\\"sensor\\\"\\n\"",
        "  \"mask: \\\"solid\\\"\\n\"",
        "  \"embedded_collision_shape {\\n\"",
        "  \"  shapes {\\n\"",
        "  \"    shape_type: TYPE_BOX\\n\"",
        "  \"    position { x: 0.0 y: 0.0 z: 0.0 }\\n\"",
        "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\"",
        "  \"    index: 0\\n\"",
        "  \"    count: 3\\n\"",
        "  \"  }\\n\"",
        -- Defold stores box shape extents as half-size values.
        "  \"  data: " .. fmt_num(half_w) .. "\\n\"",
        "  \"  data: " .. fmt_num(half_h) .. "\\n\"",
        "  \"  data: 10.0\\n\"",
        "  \"}\\n\"",
        "  \"locked_rotation: true\\n\"",
        "  \"\"",
        "}",
        -- Keep pushable identity separate from the physical WORLD body. The
        -- elevator rider sensor masks this trigger group, so ordinary WORLD
        -- collision objects can never be mistaken for movable passengers.
        "embedded_components {",
        "  id: \"pushable_tag\"",
        "  type: \"collisionobject\"",
        "  data: \"collision_shape: \\\"\\\"\\n\"",
        "  \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"pushable\\\"\\n\"",
        "  \"mask: \\\"solid\\\"\\n\"",
        "  \"embedded_collision_shape {\\n\"",
        "  \"  shapes {\\n\"",
        "  \"    shape_type: TYPE_BOX\\n\"",
        "  \"    position { x: 0.0 y: 0.0 z: 0.0 }\\n\"",
        "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\"",
        "  \"    index: 0\\n\"",
        "  \"    count: 3\\n\"",
        "  \"  }\\n\"",
        "  \"  data: " .. fmt_num(half_w) .. "\\n\"",
        "  \"  data: " .. fmt_num(half_h) .. "\\n\"",
        "  \"  data: 10.0\\n\"",
        "  \"}\\n\"",
        "  \"\"",
        "}",
    }

    -- In import-time baked mode, the visual comes from the chunk tilemap and
    -- this fallback sprite would show as an extra rectangle in the IDE.
    if chunk_baked ~= true then
        rows[#rows + 1] = "embedded_components {"
        rows[#rows + 1] = "  id: \"sprite\""
        rows[#rows + 1] = "  type: \"sprite\""
        rows[#rows + 1] = "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\""
        rows[#rows + 1] = "  \"default_animation: \\\"wall_base\\\"\\n\""
        rows[#rows + 1] = "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\""
        rows[#rows + 1] = "  \"blend_mode: BLEND_MODE_ALPHA\\n\""
        rows[#rows + 1] = "  \"\""
        rows[#rows + 1] = "  scale {"
        rows[#rows + 1] = "    x: " .. fmt_num(sx)
        rows[#rows + 1] = "    y: " .. fmt_num(sy)
        rows[#rows + 1] = "    z: 1.0"
        rows[#rows + 1] = "  }"
        rows[#rows + 1] = "}"
    end

    rows[#rows + 1] = ""
    return table.concat(rows, "\n")
end

local function gen_hazard_zone_go(width, height)
    local half_w, half_h
    if CollisionBox and CollisionBox.full_to_half_extents then
        half_w, half_h = CollisionBox.full_to_half_extents(width, height, 128, 64)
    else
        local w = tonumber(width) or 128
        local h = tonumber(height) or 64
        if w <= 0 then w = 128 end
        if h <= 0 then h = 64 end
        half_w = w * 0.5
        half_h = h * 0.5
    end

    return table.concat({
        "components {",
        "  id: \"hazard_zone\"",
        "  component: \"/mvtk/world/hazard_zone.script\"",
        "}",
        "embedded_components {",
        "  id: \"collision\"",
        "  type: \"collisionobject\"",
        "  data: \"collision_shape: \\\"\\\"\\n\"",
        "  \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.1\\n\"",
        "  \"restitution: 0.5\\n\"",
        "  \"group: \\\"hazard\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"embedded_collision_shape {\\n\"",
        "  \"  shapes {\\n\"",
        "  \"    shape_type: TYPE_BOX\\n\"",
        "  \"    position { x: 0.0 y: 0.0 z: 0.0 }\\n\"",
        "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\"",
        "  \"    index: 0\\n\"",
        "  \"    count: 3\\n\"",
        "  \"  }\\n\"",
        "  \"  data: " .. fmt_num(half_w) .. "\\n\"",
        "  \"  data: " .. fmt_num(half_h) .. "\\n\"",
        "  \"  data: 10.0\\n\"",
        "  \"}\\n\"",
        "  \"\"",
        "}",
        "",
    }, "\n")
end

local function gen_ladder_go(width, height)
    local half_w, half_h
    if CollisionBox and CollisionBox.full_to_half_extents then
        half_w, half_h = CollisionBox.full_to_half_extents(width, height, 32, 128)
    else
        local w = tonumber(width) or 32
        local h = tonumber(height) or 128
        if w <= 0 then w = 32 end
        if h <= 0 then h = 128 end
        half_w = w * 0.5
        half_h = h * 0.5
    end

    return table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/ladder.script\"",
        "}",
        "embedded_components {",
        "  id: \"collisionobject\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"ladder\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"embedded_collision_shape {\\n\"",
        "  \"  shapes {\\n\"",
        "  \"    shape_type: TYPE_BOX\\n\"",
        "  \"    position { x: 0.0 y: 0.0 z: 0.0 }\\n\"",
        "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\"",
        "  \"    index: 0\\n\"",
        "  \"    count: 3\\n\"",
        "  \"  }\\n\"",
        "  \"  data: " .. fmt_num(half_w) .. "\\n\"",
        "  \"  data: " .. fmt_num(half_h) .. "\\n\"",
        "  \"  data: 5.0\\n\"",
        "  \"}\\n\"",
        "  \"\"",
        "}",
        "",
    }, "\n")
end

local function resolve_half_extents(width, height, fallback_w, fallback_h)
    local half_w, half_h, w, h
    if CollisionBox and CollisionBox.full_to_half_extents then
        half_w, half_h, w, h = CollisionBox.full_to_half_extents(width, height, fallback_w, fallback_h)
    else
        w = tonumber(width) or tonumber(fallback_w) or 128
        h = tonumber(height) or tonumber(fallback_h) or w
        if w <= 0 then w = tonumber(fallback_w) or 128 end
        if h <= 0 then h = tonumber(fallback_h) or w end
        half_w = w * 0.5
        half_h = h * 0.5
    end
    return half_w, half_h, w, h
end

local function sprite_scale_from_base(width, height, base_w, base_h)
    local w = tonumber(width) or tonumber(base_w) or 128
    local h = tonumber(height) or tonumber(base_h) or w
    local bw = tonumber(base_w) or 128
    local bh = tonumber(base_h) or bw
    if w <= 0 then w = bw end
    if h <= 0 then h = bh end
    if bw <= 0 then bw = 128 end
    if bh <= 0 then bh = bw end
    local sx = (bw ~= 0) and (w / bw) or 1
    local sy = (bh ~= 0) and (h / bh) or 1
    return sx, sy
end

--- Locate the embedded_components block containing `id: "sprite"` in a
--- proto text. Returns (block_start, block_end, scale_start, scale_end)
--- line indices, where scale_* are nil if no scale block exists yet.
local function find_sprite_embedded_block(lines)
    local i, n = 1, #lines
    while i <= n do
        if lines[i]:match("^embedded_components%s*{") then
            local depth = 1
            local is_sprite = false
            local scale_s, scale_e = nil, nil
            local j = i + 1
            while j <= n and depth > 0 do
                local line = lines[j]
                if line:match('^%s*id:%s*"sprite"%s*$') then
                    is_sprite = true
                end
                if is_sprite and depth == 1 and line:match("^%s*scale%s*{") then
                    scale_s = j
                    local sd = 1
                    local k = j
                    -- scale { may be on same line as close; account for that
                    sd = sd + brace_delta(line) - 1 -- we already counted the opening brace
                    if sd == 0 then
                        scale_e = k
                    else
                        k = k + 1
                        while k <= n do
                            sd = sd + brace_delta(lines[k])
                            if sd == 0 then scale_e = k; break end
                            k = k + 1
                        end
                    end
                end
                depth = depth + brace_delta(line)
                if depth == 0 then
                    if is_sprite then
                        return i, j, scale_s, scale_e
                    end
                    break
                end
                j = j + 1
            end
            i = j + 1
        else
            i = i + 1
        end
    end
    return nil
end

--- Locate the first collision shape `data:` lines inside an
--- embedded_components block of type `collisionobject`. Returns the three
--- line indices of the half_w, half_h, half_d data entries (the first box
--- shape encountered). Returns nil if the block can't be found.
local function find_collision_data_lines(lines)
    local groups = {}
    local i, n = 1, #lines
    while i <= n do
        if lines[i]:match("^embedded_components%s*{") then
            local depth = 1
            local is_collision = false
            local j = i + 1
            local data_idx = {}
            while j <= n and depth > 0 do
                local line = lines[j]
                if line:match('^%s*type:%s*"collisionobject"%s*$') then
                    is_collision = true
                end
                if is_collision and line:match('^%s*"%s*data:%s*[%-%+%.%deE]+\\n"%s*$') then
                    data_idx[#data_idx + 1] = j
                end
                depth = depth + brace_delta(line)
                if depth == 0 then
                    if is_collision and #data_idx >= 3 then
                        groups[#groups + 1] = { data_idx[1], data_idx[2], data_idx[3] }
                    end
                    break
                end
                j = j + 1
            end
            i = j + 1
        else
            i = i + 1
        end
    end
    if #groups == 0 then
        return nil
    end
    -- Also return the first group's indices positionally so callers can keep
    -- using the simple (d1, d2, d3 = find_collision_data_lines(lines)) form.
    local first = groups[1]
    return first[1], first[2], first[3], groups
end

local function set_boolean_property_value(text, property_id, value)
    local escaped_id = tostring(property_id):gsub("([^%w])", "%%%1")
    local prefix = '(properties%s*{%s*id:%s*"' .. escaped_id .. '"%s*value:%s*")'
    return (tostring(text):gsub(prefix .. '[^"]*(")', "%1" .. (value and "true" or "false") .. "%2"))
end

--- Patch a source prefab .go proto to bake in the correct collision
--- half-extents and sprite scale for a specific Tiled rectangle instance.
--- This lets the generated per-instance .go be referenced from a collection
--- with scale3 = (1, 1, 1), which is the only way to get accurate box
--- collision sizes in Defold Box2D when the authored rectangle has a
--- non-uniform aspect ratio (Box2D only supports uniform collision
--- scaling via the game object transform).
--
-- @param source_text   Full prefab .go text (as read from the project)
-- @param full_w        Authored (Tiled) full width in pixels
-- @param full_h        Authored (Tiled) full height in pixels
-- @param base_half_w   Prefab's base collision half-width (pre-scale)
-- @param base_half_h   Prefab's base collision half-height (pre-scale)
-- @param fallback_w    Fallback full width for the resolver helper
-- @param fallback_h    Fallback full height for the resolver helper
-- @return string|nil, string|nil   patched_text, error
local function gen_sized_rect_instance_go(source_text, full_w, full_h, base_half_w, base_half_h, fallback_w, fallback_h, options)
    if type(source_text) ~= "string" or source_text == "" then
        return nil, "source_text empty"
    end

    -- Use the canonical helper so collision math stays in one place.
    local half_w, half_h = resolve_half_extents(full_w, full_h, fallback_w, fallback_h)
    local sx, sy = sprite_scale_from_base(full_w, full_h, (tonumber(base_half_w) or 64) * 2, (tonumber(base_half_h) or 64) * 2)

    local lines = split_proto_lines(source_text)

    -- Patch collision half-extents on EVERY collisionobject (e.g. door_blocker
    -- has both a static "co" and a trigger "sensor" that must match). The
    -- third data line per group is the Z half-depth and is left untouched.
    local _, _, _, groups = find_collision_data_lines(lines)
    if not groups or #groups == 0 then
        return nil, "collision data lines not found"
    end
    for _, g in ipairs(groups) do
        lines[g[1]] = string.format('  "  data: %s\\n"', fmt_num(half_w))
        lines[g[2]] = string.format('  "  data: %s\\n"', fmt_num(half_h))
    end

    -- Patch (or insert) sprite scale so visuals match the authored rect
    -- without needing scale3 on the collection instance.
    local block_start, block_end, scale_s, scale_e = find_sprite_embedded_block(lines)
    if block_start and block_end then
        local scale_block = {
            "  scale {",
            "    x: " .. fmt_num(sx),
            "    y: " .. fmt_num(sy),
            "    z: 1.0",
            "  }",
        }
        local new_lines = {}
        if scale_s and scale_e then
            for k = 1, scale_s - 1 do new_lines[#new_lines + 1] = lines[k] end
            for _, l in ipairs(scale_block) do new_lines[#new_lines + 1] = l end
            for k = scale_e + 1, #lines do new_lines[#new_lines + 1] = lines[k] end
        else
            for k = 1, block_end - 1 do new_lines[#new_lines + 1] = lines[k] end
            for _, l in ipairs(scale_block) do new_lines[#new_lines + 1] = l end
            for k = block_end, #lines do new_lines[#new_lines + 1] = lines[k] end
        end
        lines = new_lines
    end

    local result = table.concat(lines, "\n") .. "\n"
    if options and options.use_defold_sprite ~= nil then
        result = set_boolean_property_value(result, "show_sprite", options.use_defold_sprite)
        if options.use_defold_sprite == false then
            result = proto_utils.strip_sprite_components(result)
        end
    end
    return result
end

--- Convert a Tiled image-layer offset (top-left, Y-down) to a Defold
--- sprite center position (center, Y-up).
-- @param offset_x  Tiled offsetx for the image layer
-- @param offset_y  Tiled offsety for the image layer
-- @param img_w     Width of the source image in pixels
-- @param img_h     Height of the source image in pixels
-- @param map_height  Total map height in pixels (tiles * tileheight)
-- @return pos_x, pos_y  Defold sprite center coordinates
local function tiled_image_layer_to_defold_pos(offset_x, offset_y, img_w, img_h, map_height)
    local ox = tonumber(offset_x) or 0
    local oy = tonumber(offset_y) or 0
    local w  = tonumber(img_w) or 0
    local h  = tonumber(img_h) or 0
    local mh = tonumber(map_height) or 0
    local pos_x = ox + (w * 0.5)
    local pos_y = (mh - oy) - (h * 0.5)
    return pos_x, pos_y
end



M.LEVEL_GO_TEMPLATE = LEVEL_GO_TEMPLATE
M.sanitize_collision_group_text = sanitize_collision_group_text
M.gen_level_go = gen_level_go
M.gen_level_tilecol_go = gen_level_tilecol_go
M.gen_backgrounds_go = gen_backgrounds_go
M.gen_pushable_block_go = gen_pushable_block_go
M.gen_hazard_zone_go = gen_hazard_zone_go
M.gen_ladder_go = gen_ladder_go
M.resolve_half_extents = resolve_half_extents
M.sprite_scale_from_base = sprite_scale_from_base
M.gen_sized_rect_instance_go = gen_sized_rect_instance_go
M.strip_sprite_components = proto_utils.strip_sprite_components
M.tiled_image_layer_to_defold_pos = tiled_image_layer_to_defold_pos

return M
