-- mvtk/player/player_scale.lua
-- Produces the one-time, runtime-scaled view of player_settings.lua.

local M = {}

-- Uniform Player Size limits (unitless): include old 0.25..8 values and
-- their conversion to the new units; safe range 1/7..8.
M.MIN_SCALE = 0.25 / 1.75
M.MAX_SCALE = 8.0

M.SCALED_KEYS = {
    always = {
        "collider_half_height",
        "collider_half_width",
        "foot_floor_adjust",
        "head_margin",
        "roll.small_half_width",
        "roll.small_half_height",
    },
    movement = {
        "walk_speed",
        "run_speed",
        "stop_epsilon",
        "gravity",
        "jump_height",
        "extended_jump_height",
        "landing_snap_distance",
        "slide.speed",
        "air_dash.speed",
        "wall_climb.speed",
        "wall_climb.climb_speed",
        "wall_climb.stick_speed",
        "wall_climb.wall_jump.slide_fall_speed",
        "wall_climb.ledge_climb.climb_x",
        "wall_climb.ledge_climb.climb_y",
        "block_grab.pull_speed",
        "glide.max_fall_speed",
        "ground_pound.slam_speed",
        "ground_pound.impact_bounce",
        "grapple.range_px",
        "grapple.pull_speed",
        "grapple.swing_acceleration",
        "grapple.swing_max_speed",
        "grapple.swing_speed_limit",
        "grapple.rope_length_px",
        "grapple.min_rope_length_px",
        "grapple.reel_speed",
        "grapple.surface_clearance_px",
        "grapple.release_boost_px",
        "grapple.release_up_boost_px",
        "grapple.impact_release_speed",
        "grapple.occlusion_tolerance_px",
        "grapple.ground_clearance_px",
        "grapple.launch_reel_speed",
        "grapple.arrival_distance_px",
    },
}

-- Only these companion-file fields carry Player Size units. Array indexes
-- identify the first active window/hitbox, matching the combat resolver.
M.FILE_SCALED_KEYS = {
    combat_config = {
        always = {
            "attacks.light_1.timeline.active_windows.1.hitboxes.1.width",
            "attacks.light_1.timeline.active_windows.1.hitboxes.1.height",
            "attacks.heavy_1.timeline.active_windows.1.hitboxes.1.width",
            "attacks.heavy_1.timeline.active_windows.1.hitboxes.1.height",
        },
        movement = { "attacks.ranged_shot.timeline.active_windows.1.projectile.speed" },
    },
    combat_overrides = {
        always = {
            "combat.melee_light.hitbox.width", "combat.melee_light.hitbox.height",
            "combat.melee_heavy.hitbox.width", "combat.melee_heavy.hitbox.height",
        },
        movement = { "combat.ranged.projectile_speed" },
    },
    player_art = {
        always = { "width", "height", "offset_x", "offset_y" },
        movement = {},
    },
}

local function deep_copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, entry in pairs(value) do
        result[deep_copy(key, seen)] = deep_copy(entry, seen)
    end
    return result
end

local function normalize_scale(value)
    local scale = tonumber(value)
    if not scale then
        if value ~= nil and print then
            print("[PLAYER_SCALE] WARNING: player_scale must be a number; using 1.0")
        end
        return 1.0
    end
    if scale < M.MIN_SCALE then return M.MIN_SCALE end
    if scale > M.MAX_SCALE then return M.MAX_SCALE end
    return scale
end

local function scale_path(root, path, scale)
    local parent = root
    local field
    for part in path:gmatch("[^%.]+") do
        part = tonumber(part) or part
        if field then
            if type(parent[field]) ~= "table" then return end
            parent = parent[field]
        end
        field = part
    end
    if field and type(parent[field]) == "number" then
        parent[field] = parent[field] * scale
    end
end

local function units(value)
    local version = value and value.units_version or 1
    assert(version == 1 or version == 2, "units_version must be 1 or 2")
    return version
end

function M.convert_units(config, kind, project_player)
    assert(type(config) == "table", "Player unit conversion needs a config table")
    local paths = assert(M.FILE_SCALED_KEYS[kind], "Unknown player-unit file: " .. tostring(kind))
    local source, target = units(config), units(project_player)
    if source == target then return config, false end
    local result = deep_copy(config)
    local factor = target == 2 and 1.75 or 1 / 1.75
    for _, path in ipairs(paths.always) do scale_path(result, path, factor) end
    if not project_player or project_player.scale_movement ~= false then
        for _, path in ipairs(paths.movement) do scale_path(result, path, factor) end
    end
    result.units_version = target
    return result, true
end

function M.conversion_info(config, kind, project_player)
    local paths = assert(M.FILE_SCALED_KEYS[kind], "Unknown player-unit file: " .. tostring(kind))
    local source, target = units(config), units(project_player)
    if source == target then return nil end
    local fields = {}
    for _, path in ipairs(paths.always) do fields[#fields + 1] = path end
    if not project_player or project_player.scale_movement ~= false then
        for _, path in ipairs(paths.movement) do fields[#fields + 1] = path end
    end
    return kind .. ".lua uses the " .. (source == 1 and "old" or "new")
        .. " player units and is converted when loaded. Update it from the toolkit, or "
        .. (target == 2 and "multiply " or "divide ") .. table.concat(fields, ", ")
        .. " by 1.75 and add units_version = " .. tostring(target) .. "."
end

function M.apply(ps)
    if type(ps) ~= "table" then return ps end
    if ps._player_scale_applied then return ps end

    local result = deep_copy(ps)
    local scale = normalize_scale(result.player_scale)
    result.player_scale = scale
    for _, path in ipairs(M.SCALED_KEYS.always) do
        scale_path(result, path, scale)
    end
    if result.scale_movement ~= false then
        for _, path in ipairs(M.SCALED_KEYS.movement) do
            scale_path(result, path, scale)
        end
    end
    result._player_scale_applied = true
    return result
end

return M
