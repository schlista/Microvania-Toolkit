-- mvtk/bosses/movement_strategies.lua
-- ============================================================================
-- Boss Movement Strategies
-- ============================================================================
-- Dispatches per-phase movement behavior when the boss is in its IDLE state
-- (i.e. between attacks). Each strategy picks the animation key and updates
-- the boss position for that frame.
--
-- Strategies are selected by a phase's `movement_profile` field:
--   "ground_chase" | "hover" | "jump_attack" | "teleport" | "stationary" |
--   "wall_crawl" | "burrow" | "flying_patrol"
-- Every value of Tiled's `movement_profiles` enum needs an entry here
-- (test/boss_movement_profile_tests.lua); an unknown name logs once and falls
-- back to ground_chase.
--
-- To add a custom strategy:
--   1. Add a function to M.strategies below.
--   2. Expose its id in developer/config/ (or just name it and author the
--      phase in Tiled with movement_profile = <that_id>).
-- ============================================================================

local Util = require "mvtk.core.util"
local Detection = require "mvtk.enemies.detection"
local BossAnimations = Util.require_module("mvtk.bosses.boss_animations")

local M = {}

local function anim(boss, key)
    if BossAnimations and BossAnimations.resolve then
        return BossAnimations.resolve(boss, key)
    end
    return key
end

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

local function play(boss, key, loop)
    if boss and boss.play_animation then
        boss:play_animation(anim(boss, key), loop ~= false)
    end
end

local function distance_to_player(boss)
    local player_pos = Detection.get_player_position()
    local boss_pos = boss:get_position()
    if not (player_pos and boss_pos) then
        return math.huge, nil, nil
    end
    return vmath.length(player_pos - boss_pos), player_pos, boss_pos
end

local function speed_for_phase(boss, base_speed)
    local mult = (boss.boss_data and boss.boss_data.speed_multiplier) or 1.0
    return (base_speed or 120) * mult
end

-- ----------------------------------------------------------------------------
-- Strategies
-- ----------------------------------------------------------------------------

M.strategies = {}

--- ground_chase: default. Walk/run toward player; idle when in range.
function M.strategies.ground_chase(boss, ctx, dt)
    local attack_distance, player_pos, boss_pos = M.attack_distance(boss, ctx)
    local in_range = attack_distance <= ctx.attack_range
    local too_close = attack_distance < ctx.min_chase_distance

    if player_pos and boss_pos and not in_range and not too_close then
        local target = vmath.vector3(player_pos.x, boss_pos.y, boss_pos.z)
        boss:move_toward(target, speed_for_phase(boss, ctx.chase_speed), dt)
        play(boss, "walk", true)
        return "moving"
    end

    if boss.current_animation == anim(boss, "walk") then
        play(boss, "idle", true)
    end
    return "idle"
end

--- hover: bob at `hover_height` above ground; drift horizontally toward player.
function M.strategies.hover(boss, ctx, dt)
    local dist, player_pos, boss_pos = distance_to_player(boss)

    if player_pos and boss_pos then
        local target = vmath.vector3(player_pos.x, boss_pos.y, boss_pos.z)
        -- Maintain hover height relative to the boss's anchor row. If the
        -- phase declared hover_height, nudge vertically toward it.
        if ctx.hover_height and ctx.hover_height > 0 then
            local anchor_y = (boss.boss_data and boss.boss_data.spawn_y) or boss_pos.y
            target.y = anchor_y + ctx.hover_height
        end
        boss:move_toward(target, speed_for_phase(boss, ctx.chase_speed), dt)
    end

    if dist > ctx.attack_range then
        play(boss, "hover_move", true)
        return "moving"
    end

    play(boss, "hover_idle", true)
    return "idle"
end

--- jump_attack: stay in place until in range; then jump toward player.
function M.strategies.jump_attack(boss, ctx, dt)
    local dist, player_pos = distance_to_player(boss)

    -- Only commit to a jump if the player is outside attack range.
    if player_pos and dist > ctx.attack_range then
        -- Boss hops toward the player at jump_speed; visual arc is up to the
        -- animation. Position still lerps linearly.
        local jump_speed = ctx.jump_speed and ctx.jump_speed > 0 and ctx.jump_speed
            or speed_for_phase(boss, ctx.chase_speed)
        boss:move_toward(player_pos, jump_speed, dt)
        play(boss, "jump_air", true)
        return "moving"
    end

    play(boss, "idle", true)
    return "idle"
end

--- teleport: stationary between attacks; teleport is handled by attack/
--- transition logic, not the idle mover.
function M.strategies.teleport(boss, _ctx, _dt)
    play(boss, "idle", true)
    return "idle"
end

--- stationary: does not move. Faces the player unless facing_lock is set.
function M.strategies.stationary(boss, ctx, _dt)
    if ctx.facing_lock ~= true and boss.face_player then
        boss:face_player()
    end
    play(boss, "idle", true)
    return "idle"
end

--- flying_patrol: the airborne profile name shared with enemies, which map it
--- to hover too (mvtk/enemies/enemy_overrides.lua).
M.strategies.flying_patrol = M.strategies.hover

--- burrow: travels along the ground toward the player like ground_chase,
--- playing the burrow clips (boss_animations.lua falls back to move/idle when
--- a boss has no burrow art).
function M.strategies.burrow(boss, ctx, dt)
    local attack_distance, player_pos, boss_pos = M.attack_distance(boss, ctx)
    local in_range = attack_distance <= ctx.attack_range
    local too_close = attack_distance < ctx.min_chase_distance

    if player_pos and boss_pos and not in_range and not too_close then
        local target = vmath.vector3(player_pos.x, boss_pos.y, boss_pos.z)
        boss:move_toward(target, speed_for_phase(boss, ctx.chase_speed), dt)
        play(boss, "burrow_idle", true)
        return "moving"
    end

    if boss.current_animation == anim(boss, "burrow_idle") then
        play(boss, "idle", true)
    end
    return "idle"
end

--- wall_crawl: moves horizontally along the ceiling / wall plane; uses
--- crawl animations. Vertical position is held at the spawn anchor.
function M.strategies.wall_crawl(boss, ctx, dt)
    local dist, player_pos, boss_pos = distance_to_player(boss)

    if player_pos and boss_pos and dist > ctx.attack_range then
        local anchor_y = (boss.boss_data and boss.boss_data.spawn_y) or boss_pos.y
        local target = vmath.vector3(player_pos.x, anchor_y, boss_pos.z)
        boss:move_toward(target, speed_for_phase(boss, ctx.chase_speed), dt)
        play(boss, "crawl_move", true)
        return "moving"
    end

    play(boss, "crawl_idle", true)
    return "idle"
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

--- Resolve the strategy function for a profile name. Falls back to
--- ground_chase when the profile is missing or invalid.
function M.get(profile)
    if type(profile) == "string" and profile ~= "" and M.strategies[profile] then
        return M.strategies[profile]
    end
    return M.strategies.ground_chase
end

--- Resolve the actual movement profile, including the same ground-chase
--- fallback used by get().
local warned_profiles = {}

function M.resolve_profile(boss, phase)
    phase = phase or {}
    local cfg = (boss and boss.config) or {}
    local profile = phase.movement_profile or cfg.movement_profile or "ground_chase"
    if type(profile) ~= "string" or profile == "" or not M.strategies[profile] then
        local name = tostring(profile)
        if profile ~= nil and profile ~= "" and not warned_profiles[name] then
            warned_profiles[name] = true
            print("[BOSS] WARNING: unknown movement_profile '" .. name .. "'; using ground_chase")
        end
        return "ground_chase"
    end
    return profile
end

-- Profiles that move along the floor measure attack range horizontally.
local GROUNDED = { ground_chase = true, burrow = true }

--- Distance used by both movement stopping and attack gating. Grounded chase
--- ignores sprite/root vertical offsets; airborne profiles retain 2D distance.
function M.attack_distance(boss, phase)
    local euclidean, player_pos, boss_pos = distance_to_player(boss)
    if player_pos and boss_pos and GROUNDED[M.resolve_profile(boss, phase)] then
        return math.abs(player_pos.x - boss_pos.x), player_pos, boss_pos
    end
    return euclidean, player_pos, boss_pos
end

-- Run the active profile's strategy for one frame.
--   boss     — boss runtime instance (self in boss.script)
--   phase    — current phase table (may be nil; falls back to defaults)
--   defaults — numeric defaults {chase_speed, attack_range, min_chase_distance}
--   dt       — delta time
-- Returns "moving" or "idle" (for bookkeeping in callers).
function M.run(boss, phase, defaults, dt)
    phase = phase or {}
    defaults = defaults or {}
    local cfg = boss.config or {}

    local profile = M.resolve_profile(boss, phase)
    local ctx = {
        chase_speed        = cfg.chase_speed        or defaults.chase_speed        or 120,
        attack_range       = phase.attack_range     or cfg.attack_range            or defaults.attack_range or 150,
        min_chase_distance = cfg.min_chase_distance or defaults.min_chase_distance or 80,
        hover_height       = phase.hover_height       or 0,
        jump_height        = phase.jump_height        or 0,
        jump_speed         = phase.jump_speed         or 0,
        leash_radius       = phase.leash_radius       or 0,
        facing_lock        = phase.facing_lock        == true,
        movement_profile   = profile,
    }

    return M.get(profile)(boss, ctx, dt)
end

return M
