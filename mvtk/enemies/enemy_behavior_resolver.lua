-- mvtk/enemies/enemy_behavior_resolver.lua
--
-- Pure resolution of enemy-type behaviour presets plus per-instance Tiled
-- movement/attack slots.  This module intentionally has no Defold globals so
-- editor validation and plain-Lua tests can use the exact runtime rules.

local M = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function key(value)
    local s = trim(value):lower()
    return s ~= "" and s or nil
end

local INHERIT = {
    none = true,          -- legacy template sentinel
    type_default = true,  -- current, explicit UI wording
    inherit = true,
}

local DISABLED = {
    disabled = true,
    contact_only = true,
    no_attack = true,
}

function M.is_inherit(value)
    local value_key = key(value)
    return value_key == nil or INHERIT[value_key] == true
end

function M.is_disabled(value)
    local value_key = key(value)
    return value_key ~= nil and DISABLED[value_key] == true
end

-- `role` controls slot assignment. `velocity_owner = "always"` marks hybrid
-- attacks that supersede an ordinary movement pattern for their whole life.
-- Active-only attack ownership (dash, swipe, jump) is deliberate: movement
-- runs first and the attack may plant or redirect the enemy while active.
M.PATTERN_META = {
    idle =                  { role = "movement" },
    patrol_horizontal =     { role = "movement" },
    patrol_vertical =       { role = "movement" },
    ground_patrol_chase =   { role = "movement" },
    chase_ground =          { role = "movement" },
    chase_flying =          { role = "movement" },
    chase_player =          { role = "movement" }, -- direct/legacy pattern id
    flee_player =           { role = "movement" },
    zigzag_move =           { role = "movement" },
    ghost_float =           { role = "movement" },

    shoot_straight =        { role = "attack" },
    shoot_spread =          { role = "attack" },
    shoot_burst =           { role = "attack" },
    shoot_circle =          { role = "attack" },
    shoot_random =          { role = "attack" },
    melee_swipe =           { role = "attack", velocity_owner = "active" },
    dash_attack =           { role = "attack", velocity_owner = "active" },
    jump_attack =           { role = "attack", velocity_owner = "active" },
    teleport_attack =       { role = "attack", velocity_owner = "active" },
    rain_attack =           { role = "attack" },
    shield =                { role = "attack" },
    summon_minion =         { role = "attack" },
    spiral_shot =           { role = "attack" },
    homing_shot =           { role = "attack" },
    charge_shoot =          { role = "attack", velocity_owner = "active" },

    swoop_attack =          { role = "hybrid", velocity_owner = "always" },
}

-- Designer-friendly and legacy behaviour vocabulary. Aliases can expand to a
-- compound list; expansion is recursive so the canonical role table above is
-- the single source of truth.
local ALIASES = {
    patrol = "patrol_horizontal",
    patrol_h = "patrol_horizontal",
    patrol_v = "patrol_vertical",
    patrol_vertical = "patrol_vertical",
    vertical_patrol = "patrol_vertical",
    wander = "patrol_horizontal",
    hover = "patrol_vertical",
    flying_patrol = "patrol_vertical",
    patrol_flying = "patrol_vertical",
    ground_patrol = "patrol_horizontal",
    patrol_chase = "ground_patrol_chase",
    ground_patrol_chase = "ground_patrol_chase",
    flee = "flee_player",
    run_away = "flee_player",
    zigzag = "zigzag_move",
    stationary = "idle",
    static = "idle",

    shoot = "shoot_straight",
    ranged = "shoot_straight",
    spread = "shoot_spread",
    shotgun = "shoot_spread",
    burst = "shoot_burst",
    circle = "shoot_circle",
    radial = "shoot_circle",
    random = "shoot_random",
    spiral = "spiral_shot",
    homing = "homing_shot",
    swoop = "swoop_attack",
    dart = "swoop_attack",
    swipe = "melee_swipe",
    melee = "melee_swipe",
    dash = "dash_attack",
    charger = "dash_attack",
    charge = "charge_shoot",
    lunge = "dash_attack",
    jump = "jump_attack",
    leap = "jump_attack",
    teleport = "teleport_attack",
    blink = "teleport_attack",
    defend = "shield",
    block = "shield",
    summon = "summon_minion",
    spawn = "summon_minion",
    rain = "rain_attack",
    ghost = "ghost_float",

    ranged_patrol = "patrol_horizontal,shoot_straight",
    ranged_chase = "chase,shoot_straight",
    sniper = "shoot_straight",
    bomber = "patrol_horizontal,shoot_spread",
    swarmer = "chase",
    guardian = "patrol_horizontal,shield",
    summoner = "patrol_horizontal,summon_minion",
    boss_basic = "chase,dash_attack,shoot_spread",
}

M.ALIASES = ALIASES

local function canonical_chase(name, grounded)
    if name == "flying_chase" or name == "fly_chase" or name == "chase_flying" then
        return "chase_flying"
    end
    if name == "ground_chase" or name == "chase_ground" then
        return "chase_ground"
    end
    if name == "chase" or name == "follow" or name == "chase_player" then
        return grounded and "chase_ground" or "chase_flying"
    end
    return nil
end

local function expand_token(raw_name, grounded, out, unknown, depth)
    depth = depth or 0
    if depth > 8 then
        unknown[#unknown + 1] = trim(raw_name)
        return
    end

    local name = key(raw_name)
    if not name or INHERIT[name] or DISABLED[name] then
        return
    end

    local chase = canonical_chase(name, grounded)
    if chase then
        out[#out + 1] = chase
        return
    end

    local alias = ALIASES[name]
    if alias and alias ~= name then
        for part in alias:gmatch("[^,;]+") do
            expand_token(part, grounded, out, unknown, depth + 1)
        end
        return
    end

    out[#out + 1] = name
    if not M.PATTERN_META[name] then
        unknown[#unknown + 1] = name
    end
end

local function expand(value, grounded)
    local out = {}
    local unknown = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            expand_token(item, grounded, out, unknown)
        end
    elseif value ~= nil then
        for token in tostring(value):gmatch("[^,;]+") do
            expand_token(token, grounded, out, unknown)
        end
    end
    return out, unknown
end

M.expand = expand

local function add_unique(values, seen, value)
    if value and not seen[value] then
        values[#values + 1] = value
        seen[value] = true
    end
end

local function parse_base(behavior, grounded, conflicts)
    local expanded, unknown = expand(behavior, grounded)
    local movement = nil
    local attacks = {}
    local seen_attacks = {}

    for _, name in ipairs(expanded) do
        local meta = M.PATTERN_META[name]
        local role = meta and meta.role or "attack"
        if role == "movement" then
            if movement and movement ~= name then
                conflicts[#conflicts + 1] = string.format(
                    "legacy behavior defines multiple movement owners ('%s', '%s'); using '%s'",
                    movement, name, name)
            end
            -- Later movement patterns historically won because update order
            -- overwrote velocity, so use the last one for compatibility.
            movement = name
        else
            add_unique(attacks, seen_attacks, name)
        end
    end

    return movement, attacks, unknown
end

local function resolve_movement_slot(raw, inherited, grounded, conflicts, unknown)
    if M.is_inherit(raw) then
        return inherited
    end
    local raw_key = key(raw)
    if raw_key == "disabled" or raw_key == "stationary" or raw_key == "static" then
        return "idle"
    end

    local expanded, slot_unknown = expand(raw, grounded)
    for _, name in ipairs(slot_unknown) do unknown[#unknown + 1] = name end
    for _, name in ipairs(expanded) do
        local meta = M.PATTERN_META[name]
        if meta and meta.role == "movement" then
            return name
        end
    end
    conflicts[#conflicts + 1] = string.format(
        "movement slot '%s' did not resolve to a movement pattern", tostring(raw))
    return inherited
end

local function resolve_attack_slot(raw, inherited, grounded, slot_name, conflicts, unknown)
    if M.is_inherit(raw) then
        return inherited
    end
    if M.is_disabled(raw) then
        return nil
    end

    local expanded, slot_unknown = expand(raw, grounded)
    for _, name in ipairs(slot_unknown) do unknown[#unknown + 1] = name end
    for _, name in ipairs(expanded) do
        local meta = M.PATTERN_META[name]
        if not meta or meta.role == "attack" or meta.role == "hybrid" then
            return name
        end
    end
    conflicts[#conflicts + 1] = string.format(
        "%s slot '%s' did not resolve to an attack pattern", slot_name, tostring(raw))
    return inherited
end

--- Resolve an enemy type's legacy behavior and three independent Tiled slots.
-- @param opts table with behavior, grounded_movement, movement,
--        attack_pattern, and attack_pattern2.
-- @return table with canonical movement/attacks/patterns and diagnostics.
function M.resolve(opts)
    opts = opts or {}
    local grounded = opts.grounded_movement == true
    local conflicts = {}
    local unknown = {}
    local base_movement, base_attacks, base_unknown = parse_base(opts.behavior, grounded, conflicts)
    for _, name in ipairs(base_unknown) do unknown[#unknown + 1] = name end

    local movement = resolve_movement_slot(
        opts.movement, base_movement, grounded, conflicts, unknown)

    local attacks = {}
    local attack1 = resolve_attack_slot(
        opts.attack_pattern, base_attacks[1], grounded,
        "attack_pattern", conflicts, unknown)
    local attack2 = resolve_attack_slot(
        opts.attack_pattern2, base_attacks[2], grounded,
        "attack_pattern2", conflicts, unknown)

    local attack_seen = {}
    add_unique(attacks, attack_seen, attack1)
    add_unique(attacks, attack_seen, attack2)
    -- Preserve additional legacy preset attacks. Tiled exposes two slots, but
    -- old compound behaviors occasionally contain a third attack.
    for i = 3, #base_attacks do
        add_unique(attacks, attack_seen, base_attacks[i])
    end

    local patterns = {}
    local seen = {}
    add_unique(patterns, seen, movement)
    for _, attack in ipairs(attacks) do
        add_unique(patterns, seen, attack)
        local meta = M.PATTERN_META[attack]
        if movement and meta and meta.role == "hybrid" and meta.velocity_owner == "always" then
            conflicts[#conflicts + 1] = string.format(
                "hybrid attack '%s' owns movement and supersedes movement '%s'",
                attack, movement)
        end
    end

    local uses_run = movement == "chase_ground"
        or movement == "chase_flying"
        or movement == "ground_patrol_chase"

    return {
        movement = movement,
        attacks = attacks,
        patterns = patterns,
        slots = {
            movement = movement,
            attack_pattern = attack1,
            attack_pattern2 = attack2,
        },
        conflicts = conflicts,
        unknown = unknown,
        uses_run_animation = uses_run,
    }
end

return M
