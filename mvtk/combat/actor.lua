--- Actor Interface
-- Thin shared interface consumed by both enemy and boss scripts.
-- Provides a uniform API for health, damage, hit reaction, and invulnerability
-- so that systems like the behavior tree, boss minions,
-- and arena hazards can work with any combat actor without knowing whether
-- the target is a player, enemy, or boss.
--
-- Usage:
--   local Actor = require "mvtk.combat.actor"
--   Actor.init(self, { max_health = 100 })
--   Actor.apply_damage(self, payload)
--   Actor.update(self, dt)
--
-- The module never stores global state — all data lives on the `self` table
-- passed in by the caller (a Defold script instance or a manager table).
--
-- @module actor

local Invulnerability = require "mvtk.combat.invulnerability"
local HitReactionsOk, HitReactions = pcall(require, "mvtk.combat.hit_reactions")

local M = {}

--- Initialise actor fields on an instance table.
-- Safe to call more than once (won't clobber existing values).
-- @param self  The script/manager table that owns the actor data.
-- @param opts  Optional overrides: max_health, sprite_url.
function M.init(self, opts)
    opts = opts or {}
    if not self._actor then
        self._actor = true
        self.health        = self.health        or opts.max_health  or 10
        self.max_health    = self.max_health    or opts.max_health  or self.health
        self.defeated      = self.defeated      or false
        self.invulnerable  = self.invulnerable  or false
        self.sprite_url    = self.sprite_url    or opts.sprite_url
    end
end

--- Get health as a 0‥1 fraction.
function M.get_health_percent(self)
    if not self.max_health or self.max_health == 0 then return 0 end
    return math.max(0, self.health / self.max_health)
end

--- True when the actor is alive.
function M.is_alive(self)
    return self.health and self.health > 0 and not self.defeated
end

--- Apply a damage payload to the actor.
-- Respects invulnerability and applies hit reactions.
-- @param self    Actor table.
-- @param payload Damage payload table (amount,
--                iframes_on_hit, kx, ky, source, …).
-- @return final_damage (number, 0 if blocked), was_applied (bool)
function M.apply_damage(self, payload)
    if not self or self.defeated then return 0, false end
    if Invulnerability.is_invulnerable(self) then return 0, false end

    local amount = tonumber(payload.amount or payload.damage) or 0
    local final = amount

    -- Clamp to at least 1 if the source did positive damage
    if amount > 0 then final = math.max(1, final) end

    self.health = (self.health or 0) - final

    -- I-frames
    local iframes = payload.iframes_on_hit
    if iframes and iframes > 0 then
        Invulnerability.start(self, iframes, "hit")
    end

    -- Hit reaction
    if HitReactionsOk and HitReactions and payload.reaction_type then
        pcall(HitReactions.apply, self, payload)
    end

    -- Defeated?
    if self.health <= 0 then
        self.health = 0
        self.defeated = true
    end

    return final, true
end

--- Per-frame update: i-frame timers.
-- @param self Actor table.
-- @param dt   Delta time.
function M.update(self, dt)
    if not self then return end
    Invulnerability.update(self, dt)
end

--- Start invulnerability.
function M.start_iframes(self, duration, reason)
    Invulnerability.start(self, duration, reason)
end

--- Check invulnerability.
function M.is_invulnerable(self)
    return Invulnerability.is_invulnerable(self)
end

--- Clear invulnerability.
function M.clear_iframes(self)
    Invulnerability.clear(self)
end

return M
