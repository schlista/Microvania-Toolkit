--- Boss charge attack executor.
--
-- Charges are advanced from the boss ATTACKING state one frame at a time.
-- Keeping the movement here (instead of teleporting or using go.animate)
-- lets the hit test sweep every travelled segment, prevents tunnelling at
-- high speed, and gives a jumping player a real way to clear the lane.
-- @module boss_attacks.charge

local C = require "mvtk.bosses.boss_attacks.common"
local BossArena = C.Util.require_module("mvtk.bosses.boss_arena")

local M = {}

local EPSILON = 0.001

local function phase_speed_multiplier(boss)
    return tonumber(boss and boss.speed_multiplier)
        or tonumber(boss and boss.boss_data and boss.boss_data.speed_multiplier)
        or 1.0
end

local function horizontal_facing(boss, boss_pos, player_pos)
    if player_pos and math.abs((player_pos.x or 0) - (boss_pos.x or 0)) > EPSILON then
        return player_pos.x >= boss_pos.x and 1 or -1
    end
    return (boss.facing or 1) >= 0 and 1 or -1
end

local function clamp_target_to_arena(start_x, target_x, pattern)
    if not (BossArena and BossArena.get_active_arena) then
        return target_x
    end

    local arena = BossArena.get_active_arena()
    local bounds = arena and arena.bounds
    if not (bounds and tonumber(bounds.x) and tonumber(bounds.width)) then
        return target_x
    end

    local padding = math.max(0, tonumber(pattern.edge_padding) or 72)
    local left = bounds.x + padding
    local right = bounds.x + bounds.width - padding
    if right <= left or start_x < left - EPSILON or start_x > right + EPSILON then
        -- A stale/untransformed arena should never pull the boss across rooms.
        return target_x
    end
    return math.max(left, math.min(right, target_x))
end

local function charge_hits_player(ctx, from_pos, to_pos, player_pos)
    if not player_pos then return false end

    local min_x = math.min(from_pos.x, to_pos.x) - ctx.hitbox_half_width
    local max_x = math.max(from_pos.x, to_pos.x) + ctx.hitbox_half_width
    local in_swept_x = player_pos.x >= min_x and player_pos.x <= max_x
    local in_ground_lane = math.abs(player_pos.y - ctx.ground_y) <= ctx.hitbox_half_height
    return in_swept_x and in_ground_lane
end

local function damage_player(boss, ctx)
    local payload = C.build_payload(
        boss,
        ctx.pattern,
        ctx.damage,
        ctx.facing * ctx.knockback,
        ctx.knockback_y
    )
    C.post_damage(payload)
    C.print(string.format("[BOSS_ATTACKS] Charge hit player for %d damage", ctx.damage))
end

--- Arm a charge. Movement begins when update() is called by the attacking state.
function M.execute(boss, pattern)
    C.print("[BOSS_ATTACKS] Charge attack")
    M.cancel(boss)

    local pos = go.get_position()
    local player_pos = C.Detection.get_player_position()
    local facing = boss._attack_facing_locked
        and ((boss._attack_facing_locked >= 0) and 1 or -1)
        or horizontal_facing(boss, pos, player_pos)
    local dash_distance = math.max(0, tonumber(pattern.dash_distance or pattern.range) or 180)
    local base_speed = math.max(1, tonumber(pattern.dash_speed) or C.Defaults.chase_speed or 300)
    local dash_speed = base_speed * phase_speed_multiplier(boss)
    local target_x = clamp_target_to_arena(pos.x, pos.x + facing * dash_distance, pattern)
    local actual_distance = math.abs(target_x - pos.x)

    boss.facing = facing
    boss._active_charge = {
        pattern = pattern,
        facing = facing,
        speed = dash_speed,
        ground_y = pos.y,
        target_x = target_x,
        remaining = actual_distance,
        travelled = 0,
        damage = (pattern.damage or C.Defaults.default_melee_damage) * C.damage_mult(boss),
        knockback = pattern.knockback or C.Defaults.default_melee_knockback_x,
        knockback_y = pattern.knockback_y or C.Defaults.default_melee_knockback_y,
        -- The horizontal extent prevents a fast charge from tunnelling through
        -- the player's hurtbox. The vertical extent is intentionally low: get
        -- above this lane and the cactus passes safely underneath.
        hitbox_half_width = math.max(0, tonumber(pattern.hitbox_half_width) or 72),
        hitbox_half_height = math.max(0, tonumber(pattern.hitbox_half_height or pattern.width)
            or C.Defaults.default_melee_height or 80),
        recovery_remaining = math.max(0, tonumber(pattern.recovery) or 0),
        hit_player = false,
        complete = actual_distance <= EPSILON,
        finished = actual_distance <= EPSILON and (tonumber(pattern.recovery) or 0) <= 0,
    }

    C.print(string.format(
        "[BOSS_ATTACKS] Charge armed: direction=%d distance=%.0f speed=%.0f",
        facing, actual_distance, dash_speed))

    return boss._active_charge
end

--- Advance an armed charge and apply at most one swept hit.
-- @return true while travel/recovery is still active, false when complete.
function M.update(boss, _pattern, dt)
    local ctx = boss and boss._active_charge
    if not ctx then return false end
    if ctx.finished then return false end

    dt = math.max(0, tonumber(dt) or 0)
    local recovery_dt = dt

    if not ctx.complete then
        local from_pos = go.get_position()
        local step = math.min(ctx.remaining, ctx.speed * dt)
        local to_pos = vmath.vector3(
            from_pos.x + ctx.facing * step,
            ctx.ground_y,
            from_pos.z
        )

        go.set_position(to_pos)
        ctx.remaining = math.max(0, ctx.remaining - step)
        ctx.travelled = ctx.travelled + step

        if not ctx.hit_player then
            local player_pos = C.Detection.get_player_position()
            if charge_hits_player(ctx, from_pos, to_pos, player_pos) then
                ctx.hit_player = true
                damage_player(boss, ctx)
            end
        end

        local travel_dt = step / math.max(ctx.speed, 1)
        recovery_dt = math.max(0, dt - travel_dt)
        if ctx.remaining <= EPSILON then
            ctx.complete = true
            -- Land exactly on the clamped target even after small float drift.
            local final_pos = go.get_position()
            go.set_position(vmath.vector3(ctx.target_x, ctx.ground_y, final_pos.z))
            C.print(string.format(
                "[BOSS_ATTACKS] Charge travel complete: distance=%.0f",
                ctx.travelled))
        end
    end

    if ctx.complete then
        ctx.recovery_remaining = math.max(0, ctx.recovery_remaining - recovery_dt)
        ctx.finished = ctx.recovery_remaining <= EPSILON
    end

    return not ctx.finished
end

function M.is_active(boss)
    local ctx = boss and boss._active_charge
    return ctx ~= nil and not ctx.finished
end

function M.cancel(boss)
    if boss then
        boss._active_charge = nil
    end
end

-- Pure helper exposed for focused geometry tests.
M._charge_hits_player = charge_hits_player

return M
