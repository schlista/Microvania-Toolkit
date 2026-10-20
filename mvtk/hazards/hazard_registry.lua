-- mvtk/hazards/hazard_registry.lua
-- Shared hazard damage helpers. Keeps hazard scripts on the same payload,
-- clamp, and per-target cooldown contract.

local DamagePayload = require "mvtk.combat.damage_payload"

local M = {}

local DEFAULT_INSTANT_KILL_AMOUNT = 1e9

local function clone(tbl)
    local out = {}
    for k, v in pairs(tbl or {}) do
        out[k] = v
    end
    return out
end

function M.instant_kill_amount()
    return DEFAULT_INSTANT_KILL_AMOUNT
end

function M.clamp_damage(value)
    local n = tonumber(value) or 0
    if n < 0 then
        return 0
    end
    return n
end

function M.amount(value, instant_kill, instant_amount)
    if instant_kill then
        return tonumber(instant_amount) or DEFAULT_INSTANT_KILL_AMOUNT
    end
    return M.clamp_damage(value)
end

-- Tiled uses -1 for inheritance because script properties cannot be nil.
-- Zero is an explicit no-stun override; positive values are recovery seconds.
function M.stun_duration(override, fallback)
    local duration = tonumber(override)
    if duration and duration >= 0 then
        return duration
    end
    duration = tonumber(fallback)
    if duration and duration >= 0 then
        return duration
    end
    return nil
end

function M.effective_cooldown(primary, fallback, default_value)
    local cd = tonumber(primary) or 0
    if cd > 0 then
        return cd
    end

    cd = tonumber(fallback) or 0
    if cd > 0 then
        return cd
    end

    return tonumber(default_value) or 0
end

function M.tick_cooldowns(cooldowns, dt)
    if not cooldowns then
        return
    end

    dt = tonumber(dt) or 0
    for key, value in pairs(cooldowns) do
        local next_value = (tonumber(value) or 0) - dt
        if next_value <= 0 then
            cooldowns[key] = nil
        else
            cooldowns[key] = next_value
        end
    end
end

function M.cooldown_ready(cooldowns, key)
    if not cooldowns or key == nil then
        return true
    end
    return (tonumber(cooldowns[key]) or 0) <= 0
end

function M.mark_cooldown(cooldowns, key, seconds)
    if not cooldowns or key == nil then
        return
    end

    local cd = tonumber(seconds) or 0
    if cd > 0 then
        cooldowns[key] = cd
    else
        cooldowns[key] = nil
    end
end

function M.elapsed_cooldown_ready(last_damage_at, key, now, interval)
    if key == nil then
        return false
    end

    local last = last_damage_at and last_damage_at[key] or nil
    if last == nil then
        return true
    end

    return ((tonumber(now) or 0) - (tonumber(last) or 0)) >= (tonumber(interval) or 0)
end

function M.mark_elapsed_cooldown(last_damage_at, key, now)
    if last_damage_at and key ~= nil then
        last_damage_at[key] = tonumber(now) or 0
    end
end

function M.build_payload(spec)
    local payload = clone(spec)
    payload.amount = M.amount(payload.amount or payload.damage, payload.instant_kill, payload.instant_amount)
    payload.damage = payload.amount
    payload.instant_kill = nil
    payload.instant_amount = nil
    payload.message_id = nil
    payload.parryable = payload.parryable == nil and false or payload.parryable
    local normalized = DamagePayload.build(payload)
    -- Generic combat normalization fills missing stun with zero. Hazards must
    -- retain an unset duration so the player's configured recovery can apply.
    normalized.stun_t = M.stun_duration(payload.stun_t)
    return normalized
end

function M.post_damage(target, spec)
    if target == nil then
        return false, "missing target"
    end

    spec = spec or {}
    local message_id = spec.message_id or "take_damage"
    local payload = M.build_payload(spec)
    return pcall(msg.post, target, message_id, payload)
end

return M
