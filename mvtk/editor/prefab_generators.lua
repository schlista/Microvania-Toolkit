-- mvtk/editor/prefab_generators.lua
-- Pure Defold .go text builders for generated room prefabs.

local proto_utils = require("mvtk.editor.proto_utils")

local M = {}

local _resolve_half_extents = nil
local _sprite_scale_from_base = nil
local _normalize_defold_resource_path = nil
local _proto_inline_escape = nil

function M.configure(opts)
    opts = opts or {}
    if opts.resolve_half_extents ~= nil then _resolve_half_extents = opts.resolve_half_extents end
    if opts.sprite_scale_from_base ~= nil then _sprite_scale_from_base = opts.sprite_scale_from_base end
    if opts.normalize_defold_resource_path ~= nil then _normalize_defold_resource_path = opts.normalize_defold_resource_path end
    if opts.proto_inline_escape ~= nil then _proto_inline_escape = opts.proto_inline_escape end
end

local function require_collab(name, value)
    assert(value, "mvtk.editor.prefab_generators: missing collaborator '" .. name
        .. "'; configure{} must supply it before calling prefab builders")
    return value
end

local fmt_num = proto_utils.fmt_num

local function finalize_visual_go(text, use_defold_sprite, default_value)
    local use_sprite = proto_utils.bool_to_proto(use_defold_sprite, default_value) == "true"
    local property_prefix = '(properties%s*{%s*id:%s*"show_sprite"%s*value:%s*")'
    text = tostring(text):gsub(property_prefix .. '[^"]*(")', "%1" .. (use_sprite and "true" or "false") .. "%2")
    if not use_sprite then
        text = proto_utils.strip_sprite_components(text)
    end
    return text
end

local function project_tile_size_defaults()
    local ok, Tile = pcall(require, "developer.config.tile_settings")
    local w = ok and Tile and tonumber(Tile.width or Tile.tile_width or Tile.size) or nil
    local h = ok and Tile and tonumber(Tile.height or Tile.tile_height or Tile.size) or nil
    if not w or w <= 0 then w = 128 end
    if not h or h <= 0 then h = w end
    return w, h
end

local function number_to_proto(value, default)
    local n = tonumber(value)
    if n == nil then
        n = tonumber(default) or 0
    end
    return fmt_num(n)
end

local function resolve_half_extents(...)
    return require_collab("resolve_half_extents", _resolve_half_extents)(...)
end

local function sprite_scale_from_base(...)
    return require_collab("sprite_scale_from_base", _sprite_scale_from_base)(...)
end

local _resource = {}
_resource.normalize_defold_resource_path = function(...)
    return require_collab("normalize_defold_resource_path", _normalize_defold_resource_path)(...)
end
_resource.proto_inline_escape = function(value)
    local escaper = _proto_inline_escape
    if escaper then
        return escaper(value)
    end
    return proto_utils.proto_escape(value)
end

local function gen_one_way_platform_go(width, height, direction, room_id, use_defold_sprite)
    local half_w, half_h, w, h = resolve_half_extents(width, height, 256, 32)
    local sx, sy = sprite_scale_from_base(w, h, 128, 128)
    local _, collision_sy = sprite_scale_from_base(w, h, 256, 32)
    local sensor_half_h = math.max(1.0, math.min(4 * collision_sy, half_h))
    local sensor_top_y = half_h - sensor_half_h
    local sensor_bottom_y = -half_h + sensor_half_h
    local resolved_direction = tostring(direction or "down"):lower()
    if resolved_direction ~= "up" then
        resolved_direction = "down"
    end
    local resolved_room_id = tostring(room_id or "")
    local escaped_direction = proto_utils.proto_escape(resolved_direction)
    local escaped_room_id = proto_utils.proto_escape(resolved_room_id)
    return finalize_visual_go(table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/core/one_way_platform.script\"",
        "  properties {",
        "    id: \"direction\"",
        "    value: \"" .. escaped_direction .. "\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"room_id\"",
        "    value: \"" .. escaped_room_id .. "\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"show_sprite\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"sprite\"",
        "  type: \"sprite\"",
        "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"default_animation: \\\"prop_base\\\"\\n\"",
        "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\"",
        "  \"blend_mode: BLEND_MODE_ALPHA\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_KINEMATIC\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.1\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"platform\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"mask: \\\"world\\\"\\n\"",
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
        "embedded_components {",
        "  id: \"sensor\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"sensor\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"embedded_collision_shape {\\n\"",
        "  \"  shapes {\\n\"",
        "  \"    shape_type: TYPE_BOX\\n\"",
        "  \"    position { x: 0.0 y: " .. fmt_num(sensor_top_y) .. " z: 0.0 }\\n\"",
        "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\"",
        "  \"    index: 0\\n\"",
        "  \"    count: 3\\n\"",
        "  \"  }\\n\"",
        "  \"  data: " .. fmt_num(half_w) .. "\\n\"",
        "  \"  data: " .. fmt_num(sensor_half_h) .. "\\n\"",
        "  \"  data: 10.0\\n\"",
        "  \"}\\n\"",
        "  \"\"",
        "}",
        "embedded_components {",
        "  id: \"sensor_bottom\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"sensor\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"embedded_collision_shape {\\n\"",
        "  \"  shapes {\\n\"",
        "  \"    shape_type: TYPE_BOX\\n\"",
        "  \"    position { x: 0.0 y: " .. fmt_num(sensor_bottom_y) .. " z: 0.0 }\\n\"",
        "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\"",
        "  \"    index: 0\\n\"",
        "  \"    count: 3\\n\"",
        "  \"  }\\n\"",
        "  \"  data: " .. fmt_num(half_w) .. "\\n\"",
        "  \"  data: " .. fmt_num(sensor_half_h) .. "\\n\"",
        "  \"  data: 10.0\\n\"",
        "  \"}\\n\"",
        "  \"\"",
        "}",
        "embedded_components {",
        "  id: \"attack_trigger\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"breakable\\\"\\n\"",
        "  \"mask: \\\"attack\\\"\\n\"",
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
    }, "\n"), use_defold_sprite, false)
end

local function gen_platform_tilemap(tilemap_resource, width, height, tile_width, tile_height)
    local resource = _resource.normalize_defold_resource_path(tilemap_resource, ".tilesource")
    if not resource then
        return nil, "platform tilemap requires an existing .tilesource resource"
    end
    local fallback_w, fallback_h = project_tile_size_defaults()
    local px_w = tonumber(width) or tonumber(tile_width) or fallback_w
    local px_h = tonumber(height) or tonumber(tile_height) or fallback_h
    local tile_w = tonumber(tile_width) or fallback_w
    local tile_h = tonumber(tile_height) or tile_w

    if px_w <= 0 then px_w = tile_w end
    if px_h <= 0 then px_h = tile_h end
    if tile_w <= 0 then tile_w = fallback_w end
    if tile_h <= 0 then tile_h = tile_w end

    local tiles_wide = math.max(1, math.ceil(px_w / tile_w))
    local tiles_tall = math.max(1, math.ceil(px_h / tile_h))
    local rows = {
        string.format('tile_set: "%s"', resource),
        'material: "/builtins/materials/tile_map.material"',
        "blend_mode: BLEND_MODE_ALPHA",
        "",
        "layers {",
        '  id: "solid"',
        "  z: 0.1",
        "  is_visible: 1",
    }

    for y = 0, tiles_tall - 1 do
        for x = 0, tiles_wide - 1 do
            rows[#rows + 1] = string.format("  cell { x: %d y: %d tile: 0 }", x, y)
        end
    end

    rows[#rows + 1] = "}"
    rows[#rows + 1] = ""
    return table.concat(rows, "\n"), nil
end

local function gen_platform_collision_go(center_x, half_w, co_half_h, co_center_y, sensor_half_h, sensor_center_y)
    return table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/platform_collision_forwarder.script\"",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_KINEMATIC\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.1\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"solid\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"mask: \\\"world\\\"\\n\"",
        "  \"embedded_collision_shape {\\n\"",
        "  \"  shapes {\\n\"",
        "  \"    shape_type: TYPE_BOX\\n\"",
        "  \"    position { x: " .. fmt_num(center_x) .. " y: " .. fmt_num(co_center_y) .. " z: 0.0 }\\n\"",
        "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\"",
        "  \"    index: 0\\n\"",
        "  \"    count: 3\\n\"",
        "  \"  }\\n\"",
        "  \"  data: " .. fmt_num(half_w) .. "\\n\"",
        "  \"  data: " .. fmt_num(co_half_h) .. "\\n\"",
        "  \"  data: 10.0\\n\"",
        "  \"}\\n\"",
        "  \"\"",
        "}",
        "embedded_components {",
        "  id: \"sensor\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"surface\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"embedded_collision_shape {\\n\"",
        "  \"  shapes {\\n\"",
        "  \"    shape_type: TYPE_BOX\\n\"",
        "  \"    position { x: " .. fmt_num(center_x) .. " y: " .. fmt_num(sensor_center_y) .. " z: 0.0 }\\n\"",
        "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\"",
        "  \"    index: 0\\n\"",
        "  \"    count: 3\\n\"",
        "  \"  }\\n\"",
        "  \"  data: " .. fmt_num(half_w) .. "\\n\"",
        "  \"  data: " .. fmt_num(sensor_half_h) .. "\\n\"",
        "  \"  data: 10.0\\n\"",
        "  \"}\\n\"",
        "  \"\"",
        "}",
        "",
    }, "\n")
end

local function gen_tile_platform_go(_, _, _, _, _, tilemap_resource)
    return table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/tile_platform.script\"",
        "}",
        "components {",
        "  id: \"tilemap\"",
        "  component: \"" .. tostring(tilemap_resource or "/developer/game/prefabs/tile_moving_platform.tilemap") .. "\"",
        "}",
        "",
    }, "\n")
end

local function gen_tile_platform_collision_go(width, height, collision_height, co_y_offset, sensor_y_offset)
    local fallback_w, fallback_h = project_tile_size_defaults()
    local full_w = tonumber(width) or fallback_w
    local full_h = tonumber(height) or fallback_h
    if full_w <= 0 then full_w = fallback_w end
    if full_h <= 0 then full_h = fallback_h end

    local co_h = tonumber(collision_height) or full_h
    if co_h <= 0 then co_h = full_h end

    local center_x = full_w * 0.5
    local half_w = full_w * 0.5
    local co_half_h = co_h * 0.5
    local co_center_y = co_half_h + (tonumber(co_y_offset) or 0)
    local sensor_half_h = math.max(2.0, math.min(8.0, co_h * 0.125))
    -- Rider sensor straddles the walking surface (centered on the collision
    -- top) so colliders RESTING on the platform overlap it. With Spine bone
    -- physics the only collider at surface level is the foot probe, which
    -- masks "surface" (conveyor contract) but deliberately not "sensor" —
    -- hence the trigger's group below. A band inset below the top can never
    -- meet a resting foot probe, and the torso hurtbox floats too high.
    local sensor_center_y = (co_center_y + co_half_h) + (tonumber(sensor_y_offset) or 0)

    return gen_platform_collision_go(center_x, half_w, co_half_h, co_center_y, sensor_half_h, sensor_center_y)
end

local function gen_crumble_platform_go(_, _, _, _, tilemap_resource)
    return table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/crumble_platform.script\"",
        "}",
        "components {",
        "  id: \"tilemap\"",
        "  component: \"" .. tostring(tilemap_resource or "/developer/game/prefabs/tile_moving_platform.tilemap") .. "\"",
        "}",
        "",
    }, "\n")
end

local function gen_crumble_platform_collision_go(width, height, co_y_offset, sensor_y_offset)
    local half_w, half_h, full_w, full_h = resolve_half_extents(width, height, 128, 128)
    local center_x = half_w
    local co_center_y = half_h + (tonumber(co_y_offset) or 0)
    local sensor_half_h = math.max(2.0, math.min(8.0, full_h * 0.125))
    -- Same surface-straddling rider sensor as gen_tile_platform_go (see the
    -- comment there): group "surface" so Spine foot probes can enter it.
    local sensor_center_y = (co_center_y + half_h) + (tonumber(sensor_y_offset) or 0)

    return gen_platform_collision_go(center_x, half_w, half_h, co_center_y, sensor_half_h, sensor_center_y)
end

local function gen_pressure_plate_go(width, height, use_defold_sprite)
    local half_w, half_h, w, h = resolve_half_extents(width, height, 128, 32)
    local sx, sy = sprite_scale_from_base(w, h, 128, 128)
    return finalize_visual_go(table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/pressure_plate.script\"",
        "  properties {",
        "    id: \"show_sprite\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"sprite\"",
        "  type: \"sprite\"",
        "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"default_animation: \\\"prop_base\\\"\\n\"",
        "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\"",
        "  \"blend_mode: BLEND_MODE_ALPHA\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"sensor\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"mask: \\\"world\\\"\\n\"",
        "  \"mask: \\\"enemy\\\"\\n\"",
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
    }, "\n"), use_defold_sprite, false)
end

local function gen_torch_holder_go(width, height)
    local half_w, half_h, w, h = resolve_half_extents(width, height, 64, 128)
    local sx, sy = sprite_scale_from_base(w, h, 64, 128)
    return table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/torch_holder.script\"",
        "}",
        "embedded_components {",
        "  id: \"sprite\"",
        "  type: \"sprite\"",
        "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"default_animation: \\\"prop_base\\\"\\n\"",
        "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\"",
        "  \"blend_mode: BLEND_MODE_ALPHA\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"interactable\\\"\\n\"",
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

local function append_box_collision_component(rows, spec)
    local half_w = tonumber(spec and spec.half_w)
    local half_h = tonumber(spec and spec.half_h)
    if not half_w or not half_h then
        half_w, half_h = resolve_half_extents(
            spec and spec.width,
            spec and spec.height,
            spec and spec.fallback_w,
            spec and spec.fallback_h
        )
    end

    local component_id = tostring(spec and spec.id or "collision")
    local object_type = tostring(spec and spec.object_type or "TRIGGER")
    local mass = tonumber(spec and spec.mass) or 0.0
    local friction = tonumber(spec and spec.friction) or 0.0
    local restitution = tonumber(spec and spec.restitution) or 0.0
    local depth = tonumber(spec and spec.depth) or 10.0
    local pos_x = tonumber(spec and spec.pos_x) or 0.0
    local pos_y = tonumber(spec and spec.pos_y) or 0.0
    local pos_z = tonumber(spec and spec.pos_z) or 0.0
    local group = tostring(spec and spec.group or "")
    local masks = (spec and spec.masks) or {}

    rows[#rows + 1] = "embedded_components {"
    rows[#rows + 1] = string.format("  id: \"%s\"", component_id)
    rows[#rows + 1] = "  type: \"collisionobject\""
    rows[#rows + 1] = "  data: \"collision_shape: \\\"\\\"\\n\""
    rows[#rows + 1] = string.format("  \"type: COLLISION_OBJECT_TYPE_%s\\n\"", object_type)
    rows[#rows + 1] = string.format("  \"mass: %s\\n\"", fmt_num(mass))
    rows[#rows + 1] = string.format("  \"friction: %s\\n\"", fmt_num(friction))
    rows[#rows + 1] = string.format("  \"restitution: %s\\n\"", fmt_num(restitution))
    if group ~= "" then
        rows[#rows + 1] = string.format("  \"group: \\\"%s\\\"\\n\"", group)
    end
    for _, mask in ipairs(masks) do
        rows[#rows + 1] = string.format("  \"mask: \\\"%s\\\"\\n\"", tostring(mask))
    end
    rows[#rows + 1] = "  \"embedded_collision_shape {\\n\""
    rows[#rows + 1] = "  \"  shapes {\\n\""
    rows[#rows + 1] = "  \"    shape_type: TYPE_BOX\\n\""
    rows[#rows + 1] = string.format("  \"    position { x: %s y: %s z: %s }\\n\"", fmt_num(pos_x), fmt_num(pos_y), fmt_num(pos_z))
    rows[#rows + 1] = "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\""
    rows[#rows + 1] = "  \"    index: 0\\n\""
    rows[#rows + 1] = "  \"    count: 3\\n\""
    rows[#rows + 1] = "  \"  }\\n\""
    rows[#rows + 1] = string.format("  \"  data: %s\\n\"", fmt_num(half_w))
    rows[#rows + 1] = string.format("  \"  data: %s\\n\"", fmt_num(half_h))
    rows[#rows + 1] = string.format("  \"  data: %s\\n\"", fmt_num(depth))
    rows[#rows + 1] = "  \"}\\n\""
    rows[#rows + 1] = "  \"\""
    rows[#rows + 1] = "}"
end

local function gen_gate_go(width, height, use_defold_sprite)
    local half_w, half_h, w, h = resolve_half_extents(width, height, 128, 128)
    local sx, sy = sprite_scale_from_base(w, h, 128, 128)
    local rows = {
        "components {",
        "  id: \"gate\"",
        "  component: \"/mvtk/world/gates/action_barrier.script\"",
        "  properties {",
        "    id: \"gate_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"gate_type\"",
        "    value: \"ability_requirement\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"required_action\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"auto_register\"",
        "    value: \"true\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "  properties {",
        "    id: \"show_sprite\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"sprite\"",
        "  type: \"sprite\"",
        "  data: \"default_animation: \\\"gate_idle\\\"\\n\"",
        "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\"",
        "  \"textures {\\n\"",
        "  \"  sampler: \\\"texture_sampler\\\"\\n\"",
        "  \"  texture: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"}\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
    }

    append_box_collision_component(rows, {
        id = "collision",
        object_type = "STATIC",
        friction = 0.1,
        restitution = 0.5,
        group = "interactable",
        masks = { "player" },
        half_w = half_w,
        half_h = half_h,
    })
    append_box_collision_component(rows, {
        id = "trigger",
        object_type = "TRIGGER",
        group = "interactable",
        masks = { "player" },
        half_w = half_w,
        half_h = half_h,
    })
    append_box_collision_component(rows, {
        id = "attack_trigger",
        object_type = "TRIGGER",
        group = "breakable",
        masks = { "attack" },
        half_w = half_w,
        half_h = half_h,
    })

    rows[#rows + 1] = ""
    return finalize_visual_go(table.concat(rows, "\n"), use_defold_sprite, false)
end

local function gen_breakable_wall_go(width, height, use_defold_sprite)
    local half_w, half_h, w, h = resolve_half_extents(width, height, 64, 64)
    local sx, sy = sprite_scale_from_base(w, h, 128, 128)
    local rows = {
        "components {",
        "  id: \"breakable_wall\"",
        "  component: \"/mvtk/world/breakable_wall.script\"",
        "  properties {",
        "    id: \"wall_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"wall_type\"",
        "    value: \"cracked\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"required_ability\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"health\"",
        "    value: \"3.0\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"room_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"reveals_secret\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"drop_collectible\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"swap_tiles_on_break\"",
        "    value: \"true\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "  properties {",
        "    id: \"wall_layer\"",
        "    value: \"solid\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"broken_wall_layer\"",
        "    value: \"broken_wall\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"swap_width\"",
        "    value: \"" .. number_to_proto(w, 64) .. "\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"swap_height\"",
        "    value: \"" .. number_to_proto(h, 64) .. "\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"show_sprite\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"sprite\"",
        "  type: \"sprite\"",
        "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"default_animation: \\\"breakable_wall_idle\\\"\\n\"",
        "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\"",
        "  \"blend_mode: BLEND_MODE_ALPHA\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"hit_sound\"",
        "  type: \"sound\"",
        "  data: \"sound: \\\"/developer/assets/sfx/wall_hit.wav\\\"\\n\"",
        "  \"looping: 0\\n\"",
        "  \"group: \\\"sfx\\\"\\n\"",
        "  \"\"",
        "}",
        "embedded_components {",
        "  id: \"break_sound\"",
        "  type: \"sound\"",
        "  data: \"sound: \\\"/developer/assets/sfx/wall_break.wav\\\"\\n\"",
        "  \"looping: 0\\n\"",
        "  \"group: \\\"sfx\\\"\\n\"",
        "  \"\"",
        "}",
        "components {",
        "  id: \"break_effect\"",
        "  component: \"/developer/assets/fx/hit_impact.particlefx\"",
        "}",
    }

    append_box_collision_component(rows, {
        id = "collision",
        object_type = "STATIC",
        friction = 0.1,
        restitution = 0.5,
        group = "world",
        masks = { "player", "attack" },
        half_w = half_w,
        half_h = half_h,
    })
    append_box_collision_component(rows, {
        id = "attack_trigger",
        object_type = "TRIGGER",
        group = "breakable",
        masks = { "attack" },
        half_w = half_w,
        half_h = half_h,
    })

    rows[#rows + 1] = ""
    return finalize_visual_go(table.concat(rows, "\n"), use_defold_sprite, false)
end

local function gen_teleporter_go(width, height, use_defold_sprite)
    local half_w, half_h, w, h = resolve_half_extents(width, height, 128, 128)
    local sx, sy = sprite_scale_from_base(w, h, 128, 128)
    return finalize_visual_go(table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/teleporter.script\"",
        "  properties {",
        "    id: \"teleporter_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"pair_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"target_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"room_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"requires_flag\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"hide_when_locked\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "  properties {",
        "    id: \"active_effect_id\"",
        "    value: \"collectible_sparkle\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"unlock_effect_id\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "  properties {",
        "    id: \"require_interact\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "  properties {",
        "    id: \"cooldown\"",
        "    value: \"0.5\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"transition_time\"",
        "    value: \"0.0\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"preserve_velocity\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "  properties {",
        "    id: \"facing\"",
        "    value: \"0.0\"",
        "    type: PROPERTY_TYPE_NUMBER",
        "  }",
        "  properties {",
        "    id: \"label\"",
        "    value: \"\"",
        "    type: PROPERTY_TYPE_TEXT",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"sprite\"",
        "  type: \"sprite\"",
        "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"default_animation: \\\"prop_base\\\"\\n\"",
        "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\"",
        "  \"blend_mode: BLEND_MODE_ALPHA\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"interactable\\\"\\n\"",
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
    }, "\n"), use_defold_sprite, true)
end

local function gen_water_volume_go(width, height, use_defold_sprite)
    local half_w, half_h, w, h = resolve_half_extents(width, height, 128, 128)
    local sx, sy = sprite_scale_from_base(w, h, 128, 128)
    return finalize_visual_go(table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/water_volume.script\"",
        "  properties {",
        "    id: \"show_sprite\"",
        "    value: \"false\"",
        "    type: PROPERTY_TYPE_BOOLEAN",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"sprite\"",
        "  type: \"sprite\"",
        "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"default_animation: \\\"prop_base\\\"\\n\"",
        "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\"",
        "  \"blend_mode: BLEND_MODE_ALPHA\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"distortion\"",
        "  type: \"sprite\"",
        "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"default_animation: \\\"water_distortion_mask\\\"\\n\"",
        "  \"material: \\\"/developer/materials/distortion_zone.material\\\"\\n\"",
        "  \"blend_mode: BLEND_MODE_ALPHA\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"collisionobject\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"water\\\"\\n\"",
        "  \"mask: \\\"player\\\"\\n\"",
        "  \"mask: \\\"enemy\\\"\\n\"",
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
    }, "\n"), use_defold_sprite, false)
end

local function gen_bounce_pad_go(width, height, script_path, group, base_half_w, base_half_h, masks, animation_id, collision_type, component_id, use_defold_sprite)
    script_path = script_path or "/mvtk/prefabs/bounce_pad.script"
    group = group or "interactable"
    masks = (type(masks) == "table" and #masks > 0) and masks or { "player" }
    animation_id = animation_id or "prop_base"
    collision_type = collision_type or "COLLISION_OBJECT_TYPE_TRIGGER"
    component_id = component_id or "script"
    local half_w, half_h, w, h = resolve_half_extents(width, height, base_half_w or 64, base_half_h or 16)
    local sx, sy = sprite_scale_from_base(w, h, 128, 128)
    local rows = {
        "components {",
        "  id: \"" .. component_id .. "\"",
        "  component: \"" .. script_path .. "\"",
    }
    if script_path == "/mvtk/prefabs/bounce_pad.script" then
        rows[#rows + 1] = "  properties {"
        rows[#rows + 1] = "    id: \"show_sprite\""
        rows[#rows + 1] = "    value: \"false\""
        rows[#rows + 1] = "    type: PROPERTY_TYPE_BOOLEAN"
        rows[#rows + 1] = "  }"
    end
    rows[#rows + 1] = "}"
    local sprite_rows = {
        "embedded_components {",
        "  id: \"sprite\"",
        "  type: \"sprite\"",
        "  data: \"tile_set: \\\"/developer/assets/atlas/gameplay_visuals.atlas\\\"\\n\"",
        "  \"default_animation: \\\"" .. animation_id .. "\\\"\\n\"",
        "  \"material: \\\"/builtins/materials/sprite.material\\\"\\n\"",
        "  \"blend_mode: BLEND_MODE_ALPHA\\n\"",
        "  \"\"",
        "  scale {",
        "    x: " .. fmt_num(sx),
        "    y: " .. fmt_num(sy),
        "    z: 1.0",
        "  }",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"type: " .. collision_type .. "\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"" .. group .. "\\\"\\n\"",
    }
    for _, row in ipairs(sprite_rows) do
        rows[#rows + 1] = row
    end
    for _, mask in ipairs(masks) do
        rows[#rows + 1] = "  \"mask: \\\"" .. tostring(mask) .. "\\\"\\n\""
    end
    rows[#rows + 1] = "  \"embedded_collision_shape {\\n\""
    rows[#rows + 1] = "  \"  shapes {\\n\""
    rows[#rows + 1] = "  \"    shape_type: TYPE_BOX\\n\""
    rows[#rows + 1] = "  \"    position { x: 0.0 y: 0.0 z: 0.0 }\\n\""
    rows[#rows + 1] = "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\""
    rows[#rows + 1] = "  \"    index: 0\\n\""
    rows[#rows + 1] = "  \"    count: 3\\n\""
    rows[#rows + 1] = "  \"  }\\n\""
    rows[#rows + 1] = "  \"  data: " .. fmt_num(half_w) .. "\\n\""
    rows[#rows + 1] = "  \"  data: " .. fmt_num(half_h) .. "\\n\""
    rows[#rows + 1] = "  \"  data: 10.0\\n\""
    rows[#rows + 1] = "  \"}\\n\""
    rows[#rows + 1] = "  \"\""
    rows[#rows + 1] = "}"
    rows[#rows + 1] = ""
    local default_use_sprite = script_path ~= "/mvtk/prefabs/bounce_pad.script"
    return finalize_visual_go(table.concat(rows, "\n"), use_defold_sprite, default_use_sprite)
end

local function gen_collision_zone_go(script_path, width, height, default_w, default_h, group, masks, component_id, script_properties)
    script_path = script_path or "/mvtk/prefabs/ambience_zone.script"
    group = group or "sensor"
    masks = (type(masks) == "table" and #masks > 0) and masks or { "player" }
    component_id = component_id or "script"
    local fallback_w, fallback_h = project_tile_size_defaults()
    local half_w, half_h = resolve_half_extents(width, height, default_w or fallback_w, default_h or fallback_h)
    local rows = {
        "components {",
        "  id: \"" .. component_id .. "\"",
        "  component: \"" .. script_path .. "\"",
    }
    if type(script_properties) == "table" then
        for _, prop in ipairs(script_properties) do
            if type(prop) == "table" and prop.id and prop.type then
                rows[#rows + 1] = "  properties {"
                rows[#rows + 1] = "    id: \"" .. proto_utils.proto_escape(prop.id) .. "\""
                rows[#rows + 1] = "    value: \"" .. proto_utils.proto_escape(prop.value) .. "\""
                rows[#rows + 1] = "    type: " .. tostring(prop.type)
                rows[#rows + 1] = "  }"
            end
        end
    end
    rows[#rows + 1] = "}"
    rows[#rows + 1] = "embedded_components {"
    rows[#rows + 1] = "  id: \"co\""
    rows[#rows + 1] = "  type: \"collisionobject\""
    rows[#rows + 1] = "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\""
    rows[#rows + 1] = "  \"mass: 0.0\\n\""
    rows[#rows + 1] = "  \"friction: 0.0\\n\""
    rows[#rows + 1] = "  \"restitution: 0.0\\n\""
    rows[#rows + 1] = "  \"group: \\\"" .. group .. "\\\"\\n\""
    for _, mask in ipairs(masks) do
        rows[#rows + 1] = "  \"mask: \\\"" .. tostring(mask) .. "\\\"\\n\""
    end
    rows[#rows + 1] = "  \"embedded_collision_shape {\\n\""
    rows[#rows + 1] = "  \"  shapes {\\n\""
    rows[#rows + 1] = "  \"    shape_type: TYPE_BOX\\n\""
    rows[#rows + 1] = "  \"    position { x: 0.0 y: 0.0 z: 0.0 }\\n\""
    rows[#rows + 1] = "  \"    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\\n\""
    rows[#rows + 1] = "  \"    index: 0\\n\""
    rows[#rows + 1] = "  \"    count: 3\\n\""
    rows[#rows + 1] = "  \"  }\\n\""
    rows[#rows + 1] = "  \"  data: " .. fmt_num(half_w) .. "\\n\""
    rows[#rows + 1] = "  \"  data: " .. fmt_num(half_h) .. "\\n\""
    rows[#rows + 1] = "  \"  data: 10.0\\n\""
    rows[#rows + 1] = "  \"}\\n\""
    rows[#rows + 1] = "  \"\""
    rows[#rows + 1] = "}"
    rows[#rows + 1] = ""
    return table.concat(rows, "\n")
end

local function gen_checkpoint_go(width, height)
    local half_w, half_h = resolve_half_extents(width, height, 64, 64)
    return table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/checkpoint.script\"",
        "}",
        "components {",
        "  id: \"particles\"",
        "  component: \"/developer/assets/fx/collectible_sparkle.particlefx\"",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"sensor\\\"\\n\"",
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

local function gen_screen_effect_zone_go(width, height)
    local half_w, half_h = resolve_half_extents(width, height, 128, 128)
    return table.concat({
        "components {",
        "  id: \"script\"",
        "  component: \"/mvtk/prefabs/screen_effect_zone.script\"",
        "}",
        "embedded_components {",
        "  id: \"co\"",
        "  type: \"collisionobject\"",
        "  data: \"type: COLLISION_OBJECT_TYPE_TRIGGER\\n\"",
        "  \"mass: 0.0\\n\"",
        "  \"friction: 0.0\\n\"",
        "  \"restitution: 0.0\\n\"",
        "  \"group: \\\"sensor\\\"\\n\"",
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


M.gen_one_way_platform_go = gen_one_way_platform_go
M.gen_platform_tilemap = gen_platform_tilemap
M.gen_tile_platform_go = gen_tile_platform_go
M.gen_tile_platform_collision_go = gen_tile_platform_collision_go
M.gen_crumble_platform_go = gen_crumble_platform_go
M.gen_crumble_platform_collision_go = gen_crumble_platform_collision_go
M.gen_pressure_plate_go = gen_pressure_plate_go
M.gen_torch_holder_go = gen_torch_holder_go
M.gen_gate_go = gen_gate_go
M.gen_breakable_wall_go = gen_breakable_wall_go
M.gen_teleporter_go = gen_teleporter_go
M.gen_water_volume_go = gen_water_volume_go
M.gen_bounce_pad_go = gen_bounce_pad_go
M.gen_collision_zone_go = gen_collision_zone_go
M.gen_checkpoint_go = gen_checkpoint_go
M.gen_screen_effect_zone_go = gen_screen_effect_zone_go

return M
