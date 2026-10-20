-- mvtk/editor/player_scale_writer.lua
-- Deterministically bakes player visuals and collision resources for player_scale.

local M = {}
local PlayerScale = require "mvtk.player.player_scale"

M.MIN_SCALE = PlayerScale.MIN_SCALE
M.MAX_SCALE = PlayerScale.MAX_SCALE

M.BASE = {
    sprite = { width = 307.0, height = 149.5, offset_y = 43.75 },
    main = { half_width = 15.0, half_height = 30.0, half_depth = 5.0, offset_y = -10.0 },
    small = { half_width = 23.415384, half_height = 29.339373, half_depth = 10.0, offset_y = -21.0 },
    side = { half_width = 30.0, half_height = 60.0, half_depth = 10.0, offset_y = -3.0 },
    bone_body = { half_width = 24.0, half_height = 40.0, half_depth = 10.0 },
    bone_foot = { half_width = 12.0, half_height = 8.0, half_depth = 10.0 },
    bone_head = { radius = 14.0 },
}

-- New units preserve old effective sizes at 1.00; collision sizes also
-- match the crisp four-times template art (D5 body factor 1.10599).
for kind, base in pairs(M.BASE) do
    for field, value in pairs(base) do
        local body = kind ~= "sprite" and field ~= "offset_y"
        base[field] = value * 1.75 * (body and 1.10599 or 1)
    end
end

local SPRITE_TEMPLATE = [[components {
  id: "script"
  component: "/mvtk/player/player.script"
}
components {
  id: "co"
  component: "/developer/game/player/collisionobject.collisionobject"
}
components {
  id: "anim"
  component: "/mvtk/animation/animation_controller.script"
  properties {
    id: "use_spine"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "sprite_id"
    value: "#sprite"
    type: PROPERTY_TYPE_URL
  }
  properties {
    id: "default_state"
    value: "idle"
    type: PROPERTY_TYPE_TEXT
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "default_animation: \"idle\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/developer/assets/atlas/player.atlas\"\n"
  "}\n"
  "size {\n"
  "  x: %s\n"
  "  y: %s\n"
  "}\n"
  "size_mode: SIZE_MODE_MANUAL\n"
  position {
    y: %s
  }
}
]]

local COLLISION_TEMPLATES = {
    main = [[type: COLLISION_OBJECT_TYPE_KINEMATIC
mass: 0.0
friction: 0.1
restitution: 0.5
group: "player"
mask: "enemy"
mask: "attack"
mask: "sensor"
mask: "surface"
mask: "ladder"
mask: "collectible"
mask: "interactable"
mask: "world"
mask: "solid"
mask: "platform"
mask: "hazard"
mask: "water"
embedded_collision_shape {
  shapes {
    shape_type: TYPE_BOX
    position {
      y: %s
    }
    rotation {
    }
    index: 0
    count: 3
  }
  data: %s
  data: %s
  data: %s
}
locked_rotation: true
]],
    small = [[type: COLLISION_OBJECT_TYPE_KINEMATIC
mass: 0.0
friction: 0.1
restitution: 0.5
group: "player"
mask: "enemy"
mask: "attack"
mask: "sensor"
mask: "collectible"
mask: "interactable"
mask: "world"
mask: "solid"
mask: "hazard"
embedded_collision_shape {
  shapes {
    shape_type: TYPE_BOX
    position {
      y: %s
    }
    rotation {
    }
    index: 0
    count: 3
  }
  data: %s
  data: %s
  data: %s
}
locked_rotation: true
]],
    side = [[type: COLLISION_OBJECT_TYPE_KINEMATIC
mass: 0.0
friction: 0.1
restitution: 0.5
group: "player"
mask: "collectible"
mask: "interactable"
mask: "attack"
mask: "world"
mask: "solid"
mask: "hazard"
embedded_collision_shape {
  shapes {
    shape_type: TYPE_BOX
    position {
      y: %s
    }
    rotation {
    }
    index: 0
    count: 3
  }
  data: %s
  data: %s
  data: %s
}
locked_rotation: true
]],
}

local PLAYER_COLLECTION_TEMPLATE = [[name: "player"
instances {
  id: "player"
  prototype: "%s"
  children: "spine_visual"
}
instances {
  id: "spine_visual"
  prototype: "/developer/addons/spine/player/player_spine_visual.go"
  scale3 {
    x: %s
    y: %s
    z: 1.0
  }
}
instances {
  id: "body_hurtbox"
  prototype: "/developer/game/player/bone_colliders/body_hurtbox.go"
  component_properties {
    id: "bone_collider"
    properties {
      id: "part_id"
      value: "body"
      type: PROPERTY_TYPE_TEXT
    }
  }
}
instances {
  id: "foot_l"
  prototype: "/developer/game/player/bone_colliders/foot_probe.go"
  component_properties {
    id: "bone_collider"
    properties {
      id: "part_id"
      value: "foot_l"
      type: PROPERTY_TYPE_TEXT
    }
  }
}
instances {
  id: "foot_r"
  prototype: "/developer/game/player/bone_colliders/foot_probe.go"
  component_properties {
    id: "bone_collider"
    properties {
      id: "part_id"
      value: "foot_r"
      type: PROPERTY_TYPE_TEXT
    }
  }
}
instances {
  id: "head"
  prototype: "/developer/game/player/bone_colliders/head_probe.go"
  component_properties {
    id: "bone_collider"
    properties {
      id: "part_id"
      value: "head"
      type: PROPERTY_TYPE_TEXT
    }
  }
}
scale_along_z: 0
]]

local BONE_COLLISION_TEMPLATES = {
    body = [[type: COLLISION_OBJECT_TYPE_KINEMATIC
mass: 0.0
friction: 0.1
restitution: 0.5
group: "player"
mask: "enemy"
mask: "attack"
mask: "sensor"
mask: "ladder"
mask: "collectible"
mask: "interactable"
mask: "world"
mask: "solid"
mask: "platform"
mask: "hazard"
mask: "water"
embedded_collision_shape {
  shapes {
    shape_type: TYPE_BOX
    position {
    }
    rotation {
    }
    index: 0
    count: 3
  }
  data: %s
  data: %s
  data: %s
}
locked_rotation: true
]],
    foot = [[type: COLLISION_OBJECT_TYPE_KINEMATIC
mass: 0.0
friction: 0.1
restitution: 0.0
group: "player"
mask: "surface"
mask: "world"
mask: "solid"
mask: "platform"
embedded_collision_shape {
  shapes {
    shape_type: TYPE_BOX
    position {
    }
    rotation {
    }
    index: 0
    count: 3
  }
  data: %s
  data: %s
  data: %s
}
locked_rotation: true
]],
    head = [[type: COLLISION_OBJECT_TYPE_KINEMATIC
mass: 0.0
friction: 0.1
restitution: 0.0
group: "player"
mask: "world"
mask: "solid"
mask: "platform"
embedded_collision_shape {
  shapes {
    shape_type: TYPE_SPHERE
    position {
    }
    rotation {
    }
    index: 0
    count: 1
  }
  data: %s
}
locked_rotation: true
]],
}

local function normalize(path)
    return tostring(path or ""):gsub("\\", "/"):gsub("/+", "/")
end

local function join_path(a, b)
    a = normalize(a)
    b = normalize(b)
    if a == "" or a == "." then return b end
    if b == "" then return a end
    return a:gsub("/+$", "") .. "/" .. b:gsub("^/+", "")
end

local function read_text(path)
    local fh = io and io.open and io.open(path, "rb") or nil
    if not fh then return nil end
    local content = fh:read("*a")
    fh:close()
    return content
end

local function write_text(path, content)
    local fh, err = io.open(path, "wb")
    if not fh then return nil, err end
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
    fh:write(content)
    fh:close()
    return true
end

local function warn(message)
    if print then print("[PLAYER_SCALE] WARNING: " .. tostring(message)) end
end

local function clamp_scale(value, warn_invalid)
    local scale = tonumber(value)
    if not scale then
        if warn_invalid and value ~= nil then
            warn("player_scale must be a number; using 1.0")
        end
        return 1.0
    end
    if scale < M.MIN_SCALE then
        if warn_invalid then warn("player_scale is below 1/7; clamping to 1/7") end
        return M.MIN_SCALE
    end
    if scale > M.MAX_SCALE then
        if warn_invalid then warn("player_scale is above 8.0; clamping to 8.0") end
        return M.MAX_SCALE
    end
    return scale
end

local function format_number(value)
    return require("mvtk.editor.resource_text").format_number(value)
end

M.format_number = format_number

function M.generate_sprite_go(scale, player_units)
    scale = clamp_scale(scale, true)
    local base = M.BASE.sprite
    local unit_factor = player_units == 1 and 1 / 1.75 or 1
    return string.format(
        SPRITE_TEMPLATE,
        format_number(base.width * scale * unit_factor),
        format_number(base.height * scale * unit_factor),
        format_number(base.offset_y * scale * unit_factor)
    )
end

function M.generate_collisionobject(kind, scale, player_units)
    local template = COLLISION_TEMPLATES[kind]
    local base = M.BASE[kind]
    if not template or not base then
        error("unknown player collisionobject kind: " .. tostring(kind))
    end
    scale = clamp_scale(scale, true)
    local unit_factor = player_units == 1 and 1 / 1.75 or 1
    return string.format(
        template,
        format_number(base.offset_y * scale * unit_factor),
        format_number(base.half_width * scale * unit_factor),
        format_number(base.half_height * scale * unit_factor),
        format_number(base.half_depth * scale * unit_factor)
    )
end

function M.generate_player_collection(kind, scale)
    local prototype
    if kind == "spine" then
        prototype = "/developer/game/player/player_spine.go"
    elseif kind == "legacy" or kind == "main" then
        prototype = "/developer/game/player/player_main.go"
    else
        error("unknown player collection kind: " .. tostring(kind))
    end
    scale = clamp_scale(scale, true)
    local formatted = format_number(scale)
    return string.format(PLAYER_COLLECTION_TEMPLATE, prototype, formatted, formatted)
end

function M.generate_spine_collection(scale)
    return M.generate_player_collection("spine", scale)
end

function M.generate_legacy_player_collection(scale)
    return M.generate_player_collection("legacy", scale)
end

function M.generate_bone_collisionobject(kind, scale, player_units)
    local template = BONE_COLLISION_TEMPLATES[kind]
    local base = M.BASE["bone_" .. tostring(kind)]
    if not template or not base then
        error("unknown player bone collisionobject kind: " .. tostring(kind))
    end
    scale = clamp_scale(scale, true)
    local unit_factor = player_units == 1 and 1 / 1.75 or 1
    if kind == "head" then
        return string.format(template, format_number(base.radius * scale * unit_factor))
    end
    return string.format(
        template,
        format_number(base.half_width * scale * unit_factor),
        format_number(base.half_height * scale * unit_factor),
        format_number(base.half_depth * scale * unit_factor)
    )
end

function M.read_player_scale(player_settings_path)
    local text = read_text(player_settings_path)
    local baseline = {}
    if text then
        local chunk = (loadstring or load)(text, "@" .. player_settings_path)
        if chunk then
            if setfenv then setfenv(chunk, {}) end
            local ok, value = pcall(chunk)
            if ok and type(value) == "table" then baseline = value end
        end
    end
    local sibling, count = player_settings_path:gsub("player_settings%.lua$", "creator_settings.lua")
    if count == 1 then
        local authored = read_text(sibling)
        if authored then
            local chunk = assert((loadstring or load)(authored, "@" .. sibling))
            if setfenv then setfenv(chunk, {}) end
            local doc = require("mvtk.core.creator_settings_model").load_document(chunk(), baseline)
            local value = doc.published == true and doc.overrides.player and doc.overrides.player.player_scale or nil
            if value ~= nil then return clamp_scale(value, true) end
        end
    end
    if type(text) ~= "string" then return 1.0 end

    -- Ignore commented examples so documentation cannot masquerade as config.
    local uncommented = text:gsub("%-%-[^\r\n]*", "")
    local token = uncommented:match("player_scale%s*=%s*([^,%s}]+)")
    if not token then return 1.0 end
    local numeric = uncommented:match("player_scale%s*=%s*(-?[%d%.]+)")
    if not numeric or numeric ~= token or not tonumber(numeric) then
        warn("player_scale must be a number; using 1.0")
        return 1.0
    end
    return clamp_scale(tonumber(numeric), true)
end

local function write_if_changed(path, content, opts)
    if opts and opts.write_if_changed then
        local changed, err = opts.write_if_changed(path, content)
        if changed == nil then return nil, err end
        return changed == true
    end
    if read_text(path) == content then return false end
    local ok, err = write_text(path, content)
    if not ok then return nil, err end
    return true
end

function M.apply(opts)
    opts = opts or {}
    local root = opts.root or "."
    local settings_path = opts.player_settings_path
        or join_path(root, "developer/config/player_settings.lua")
    local scale = opts.scale ~= nil and clamp_scale(opts.scale, true)
        or M.read_player_scale(settings_path)
    local base = opts.base_path or join_path(root, "developer/game/player")
    -- Keep ignored add-on resources ready for the next opt-in. Core factories
    -- remain sprite-only while Off; scaling never changes their prototypes.
    local addon_base = opts.addon_base_path or join_path(root, "developer/addons/spine/player")
    local paths = {
        sprite = opts.sprite_path or join_path(base, "player_sprite.go"),
        main = opts.main_collision_path or join_path(base, "collisionobject.collisionobject"),
        small = opts.small_collision_path or join_path(base, "collisionobject_small.collisionobject"),
        side = opts.side_collision_path or join_path(base, "collisionobject_side.collisionobject"),
        player_collection = opts.player_collection_path or opts.legacy_collection_path
            or join_path(addon_base, "player.collection"),
        spine_collection = opts.spine_collection_path
            or join_path(addon_base, "player_spine.collection"),
        bone_body = opts.body_hurtbox_path
            or join_path(base, "bone_colliders/body_hurtbox.collisionobject"),
        bone_foot = opts.foot_probe_path
            or join_path(base, "bone_colliders/foot_probe.collisionobject"),
        bone_head = opts.head_probe_path
            or join_path(base, "bone_colliders/head_probe.collisionobject"),
    }
    local generated = {
        sprite = M.generate_sprite_go(scale, opts.player_units),
        main = M.generate_collisionobject("main", scale, opts.player_units),
        small = M.generate_collisionobject("small", scale, opts.player_units),
        side = M.generate_collisionobject("side", scale, opts.player_units),
        player_collection = M.generate_legacy_player_collection(scale),
        spine_collection = M.generate_spine_collection(scale),
        bone_body = M.generate_bone_collisionobject("body", scale, opts.player_units),
        bone_foot = M.generate_bone_collisionobject("foot", scale, opts.player_units),
        bone_head = M.generate_bone_collisionobject("head", scale, opts.player_units),
    }
    local written = {}
    local write_order = {
        "sprite", "main", "small", "side",
        "player_collection", "spine_collection",
        "bone_body", "bone_foot", "bone_head",
    }
    for _, kind in ipairs(write_order) do
        local changed, err = write_if_changed(paths[kind], generated[kind], opts)
        if changed == nil then
            error(string.format("could not write %s: %s", tostring(paths[kind]), tostring(err)))
        end
        if changed then written[#written + 1] = paths[kind] end
    end

    local unit_factor = opts.player_units == 1 and 1 / 1.75 or 1
    return {
        written = written,
        scale = scale,
        changed = #written > 0,
        sprite_width = M.BASE.sprite.width * scale * unit_factor,
        sprite_height = M.BASE.sprite.height * scale * unit_factor,
        collider_half_width = M.BASE.main.half_width * scale * unit_factor,
        collider_half_height = M.BASE.main.half_height * scale * unit_factor,
        spine_visual_scale = scale,
        bone_body_half_width = M.BASE.bone_body.half_width * scale * unit_factor,
        bone_body_half_height = M.BASE.bone_body.half_height * scale * unit_factor,
    }
end

-- Stage a preserved resource set for the settings transaction. The legacy
-- generators above also provide missing-file scaffolds and test fixtures.
function M.stage(opts)
    local Patch = require "mvtk.editor.player_resource_patch"
    local Model = require "mvtk.core.creator_settings_model"
    local base, read = opts.base, opts.read
    local player, previous = opts.player, opts.previous
    local manifest_path = base .. "/config/player_resources_generated.lua"
    local manifest_text = read(manifest_path)
    local player_units = Model.baseline_units(opts.baseline or player)
    if manifest_text then
        local chunk = assert((loadstring or load)(manifest_text, "@" .. manifest_path))
        if setfenv then setfenv(chunk, {}) end
        local manifest = chunk()
        assert(type(manifest) == "table" and manifest.version == 1, "Unsupported player resource manifest")
        previous = Model.copy(manifest.player)
        assert(type(previous) == "table", "Invalid player resource manifest")
        local recorded_units = manifest.player_units or 1
        assert(recorded_units == 1 or recorded_units == 2, "Invalid player resource units")
        if recorded_units ~= player_units then
            local new_scale = previous.player_scale / 1.75
            previous.player_scale = new_scale
            -- These are base halves: effective migrated dimensions / new scale.
            previous.collider_half_width = player.collider_half_width
            previous.collider_half_height = player.collider_half_height
        end
    end
    local scale = player.player_scale or 1
    local old_scale = assert(tonumber(previous.player_scale or 1))
    if not manifest_text and opts.force_geometry then
        -- On the first explicit Apply, baseline scale may already have been
        -- edited. Infer history only from an intact standard resource.
        local collection = read(base .. "/addons/spine/player/player_spine.collection")
        if collection then
            local Text = require "mvtk.editor.resource_text"
            local candidate
            for _, entry in ipairs(Text.all(Text.parse(collection).root, "instances")) do
                if Text.value(entry.node, "id") == "spine_visual" then
                    local value = Text.one(entry.node, "scale3")
                    candidate = value and Text.value(value.node, "x")
                end
            end
            assert(type(candidate) == "number" and candidate >= M.MIN_SCALE and candidate <= M.MAX_SCALE
                and collection:gsub("\r\n", "\n") == M.generate_spine_collection(candidate),
                "Custom player resources have no scale history. Save their current size in the wizard before editing baseline scale.")
            old_scale = candidate
        end
    end
    assert(old_scale >= M.MIN_SCALE and old_scale <= M.MAX_SCALE, "Invalid previous player resource scale")
    local body_changed = player.collider_half_width ~= previous.collider_half_width
        or player.collider_half_height ~= previous.collider_half_height
    local kinds = {
        ["player_sprite.go"]="sprite", ["collisionobject.collisionobject"]="main",
        ["collisionobject_small.collisionobject"]="small", ["collisionobject_side.collisionobject"]="side",
        ["player.collection"]="player_collection", ["player_spine.collection"]="spine_collection",
        ["body_hurtbox.collisionobject"]="bone_body", ["foot_probe.collisionobject"]="bone_foot",
        ["head_probe.collisionobject"]="bone_head",
    }
    local files = {}
    M.apply({ scale = old_scale, player_units = player_units, base_path = base .. "/game/player",
        addon_base_path = base .. "/addons/spine/player",
        write_if_changed = function(path, scaffold)
            local kind = assert(kinds[path:match("[^/]+$")])
            local original = read(path)
            if original and scale == old_scale and not (kind == "main" and (body_changed or opts.force_geometry)) then return false end
            local ok, content = pcall(Patch.patch, kind, original or scaffold, old_scale, player)
            assert(ok, "Cannot scale customized resource " .. path .. ": " .. tostring(content))
            if content ~= original then files[#files+1] = { path=path:sub(#base+2), content=content } end
            return false
        end,
    })
    local manifest = { version=1, player_units=player_units, player={ player_scale=scale,
        collider_half_width=player.collider_half_width, collider_half_height=player.collider_half_height } }
    files[#files+1] = { path="config/player_resources_generated.lua",
        content="-- Generated resource dimensions for repeatable player scaling. Do not edit.\n"
            .. "-- player_units records the pixel-unit generation; unitless version, safe 1 or 2.\nreturn "
            .. Model.encode(manifest) .. "\n" }
    return files
end

return M
