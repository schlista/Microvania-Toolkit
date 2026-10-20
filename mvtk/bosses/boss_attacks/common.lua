--- Shared helpers for the boss attack executors.
--
-- The boss_attacks/<type>.lua modules all import this file and use it for
-- module references, payload construction, and the few shared utility
-- functions that used to live as locals in the monolithic boss_attacks.lua.
-- Keeping them in one place avoids duplication and lets each per-type file
-- stay focused on the attack's behavior.
--
-- @module boss_attacks.common

local Util = require "mvtk.core.util"

local C = {}

-- Debug-gated print. Mirrors the previous file-local print() so per-attack
-- modules can call C.print(...) and only see output when
-- developer/config/debug_config.lua has bosses.attacks = true.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
function C.print(...)
    if _Dbg.bosses and _Dbg.bosses.attacks then
        _orig_print(...)
    end
end

C.Detection         = require "mvtk.enemies.detection"
C.Geometry          = require "mvtk.combat.attack_geometry"
C.BossAnimations    = Util.require_module("mvtk.bosses.boss_animations")
C.ProjectileSpawner = require "mvtk.combat.projectile_spawner"
C.DamagePayload     = Util.require_module("mvtk.combat.damage_payload")
C.Util              = Util
C.Defaults = Util.require_config("developer.config.boss_defaults", {
    default_melee_damage       = 2,
    default_melee_width        = 60,
    default_melee_height       = 80,
    default_melee_knockback_x  = 200,
    default_melee_knockback_y  = 100,
    default_projectile_damage  = 1,
    default_projectile_speed   = 300,
    default_projectile_life    = 3.0,
    default_aoe_damage         = 3,
    default_aoe_radius         = 150,
    default_aoe_delay          = 0.5,
    default_aoe_knockback      = 150,
    default_beam_damage        = 2,
    default_beam_length        = 400,
    default_beam_width         = 40,
    default_beam_duration      = 1.5,
    default_beam_windup        = 0.5,
    default_grab_damage        = 3,
    default_grab_duration      = 1.2,
    default_grab_throw_kb      = 350,
    default_heal_amount        = 10,
    default_buff_duration      = 4.0,
    default_shield_hp          = 25,
    default_shield_duration    = 6.0,
    default_parry_window       = 0.5,
    default_mine_damage        = 3,
    default_mine_radius        = 48,
    default_mine_lifetime      = 8.0,
    default_wave_damage        = 2,
    default_wave_rings         = 3,
    default_wave_ring_delay    = 0.35,
    default_wave_radius_step   = 80,
})

C.DAMAGE_MSG = hash("mvtk_apply_damage")

function C.damage_mult(boss)
    return (boss.boss_data and boss.boss_data.damage_multiplier) or 1.0
end

-- Build a damage payload with the attack's knockback and hit recovery.
-- Falls back to a plain table when DamagePayload is unavailable.
function C.build_payload(boss, pattern, amount, kx, ky)
    local base = {
        amount = amount,
        -- Keep the logical manager id separately while using a real GO URL as
        -- the combat source so parries/counters can message the attacker.
        source = boss.self_url or boss.boss_id,
        source_actor = boss.self_url,
        boss_id = boss.boss_id,
        dir = boss.facing,
        kx = kx,
        ky = ky,
        -- Preserve authored recovery; normalization otherwise turns a missing
        -- stun into zero and the player's movement overwrites the impulse.
        stun_t = pattern.stun_t or C.Defaults.default_hit_stun,
        reaction_type = pattern.reaction_type,
        iframes_on_hit = pattern.iframes_on_hit,
        parryable = pattern.parryable ~= false,
    }
    if C.DamagePayload and C.DamagePayload.build then
        return C.DamagePayload.build(base)
    end
    return base
end

function C.post_damage(payload)
    local player_url = C.Detection.get_player_url()
    if not player_url then return false end

    -- Detection stores a game-object URL because it is also used for position
    -- queries. Damage must target the actual player controller component.
    -- Rebuild the URL explicitly so the legacy fallback ending in `#player`
    -- cannot silently swallow combat messages (the component is `#script`).
    local target = player_url
    local ok_url, parsed = pcall(msg.url, player_url)
    if ok_url and parsed and parsed.socket and parsed.path then
        local ok_target, script_url = pcall(msg.url, parsed.socket, parsed.path, hash("script"))
        if ok_target and script_url then
            target = script_url
        end
    end

    local ok, err = pcall(msg.post, target, C.DAMAGE_MSG, payload)
    if not ok then
        C.print("[BOSS_ATTACKS] Failed to damage player:", err)
    end
    return ok
end

function C.factory_exists(component_url_string)
    local ok, url = pcall(msg.url, component_url_string)
    if not ok then return false end
    local ok2, exists = pcall(go.exists, url)
    return ok2 and exists, url
end

function C.resolve_animation_key(boss, key)
    if type(key) ~= "string" or key == "" then
        return key
    end
    if C.BossAnimations and C.BossAnimations.resolve_or_key then
        return C.BossAnimations.resolve_or_key(boss, key)
    end
    return key
end

function C.play_resolved_animation(boss, key, loop, force)
    if not (boss and boss.play_animation and key and key ~= "") then
        return
    end
    boss:play_animation(C.resolve_animation_key(boss, key), loop, force)
end

function C.play_pattern_animation(boss, pattern)
    if not (boss and pattern and pattern.animation and boss.play_animation) then
        return
    end
    -- Route attack-pattern animations through the shared boss animation
    -- contract so attack patterns can use logical keys (e.g. "swing", "slam")
    -- and first-time users only need to author the standard generic slot names.
    C.play_resolved_animation(boss, pattern.animation, false)
end

function C.copy_table(src)
    if type(C.Util) == "table" and type(C.Util.deep_copy) == "function" then
        return C.Util.deep_copy(src)
    end
    local out = {}
    for k, v in pairs(src or {}) do
        out[k] = v
    end
    return out
end

function C.merge_step_pattern(base_pattern, step)
    local merged = C.copy_table(base_pattern or {})
    for k, v in pairs(step or {}) do
        if k ~= "pattern" and k ~= "delay" then
            merged[k] = v
        end
    end
    return merged
end

-- Keep the public attack helper and cadence for callers/tests.
local Pause = require "mvtk.core.pause"
C.PAUSE_POLL = Pause.PAUSE_POLL
function C.delay(seconds, fn)
    return Pause.delay(seconds, fn)
end

-- Pattern dispatcher binding. boss_attacks.lua installs the active
-- execute_pattern() here after the dispatch table is built so combo
-- modules can re-enter dispatch without circular requires.
C._execute_pattern = nil
function C.set_execute_pattern(fn)
    C._execute_pattern = fn
end

function C.execute_pattern(boss, pattern, opts)
    if C._execute_pattern then
        return C._execute_pattern(boss, pattern, opts)
    end
end

return C
