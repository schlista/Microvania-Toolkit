--- Boss Attack Telegraphs
-- Spawns visual telegraph objects during the wind-up phase of boss attacks
-- so the player can read and react. Telegraphs are short-lived factories
-- that fade out at the end of `telegraph_time`.
--
-- Integration:
--   boss_state_machine.enter_attacking() calls M.begin(boss, pattern, duration)
--   The boss prefab must expose a factory at "#telegraph_factory" that spawns
--   tiled/templates/combat/telegraph.tx (or equivalent). If the factory is
--   absent the module degrades to a screen-shake cue only.
--
-- Telegraph shapes (set on the spawned object via go.property):
--   "line"   — horizontal swing/slam line
--   "circle" — AOE ring
--   "cone"   — directional cone (projectile volley, beam)
--
-- @module boss_telegraph

local Util = require "mvtk.core.util"
local Feedback = Util.require_module("mvtk.combat.combat_feedback")
local SafeSound = require "mvtk.audio.safe_sound"
local Defaults = Util.require_config("developer.config.boss_defaults", {
    telegraph_time = 0.5,
    default_aoe_radius = 150,
    default_melee_height = 80,
})

local M = {}

local TELEGRAPH_FACTORY = "#telegraph_factory"

local function telegraph_geometry(pattern)
    local explicit_size = pattern.telegraph_size
    local size_x = explicit_size and explicit_size.x or nil
    local size_y = explicit_size and explicit_size.y or nil
    local offset = pattern.telegraph_offset
    local shape = pattern.telegraph_shape

    if pattern.type == "aoe" and pattern.aoe then
        local radius = math.max(0,
            tonumber(pattern.aoe.radius or pattern.range) or Defaults.default_aoe_radius or 150)
        local diameter = radius * 2
        size_x = size_x or diameter
        if pattern.aoe.ground_only then
            local vertical_clearance = math.max(0,
                tonumber(pattern.aoe.vertical_clearance or pattern.aoe.jump_clearance) or 96)
            size_y = size_y or vertical_clearance * 2
            shape = shape or "line"
        else
            size_y = size_y or diameter
            shape = shape or "circle"
        end
        offset = offset or 0
    elseif pattern.type == "charge" then
        local distance = math.max(0, tonumber(pattern.dash_distance or pattern.range) or 80)
        local lane_half_height = math.max(0,
            tonumber(pattern.hitbox_half_height or pattern.width)
                or Defaults.default_melee_height or 80)
        size_x = size_x or distance
        size_y = size_y or lane_half_height * 2
        shape = shape or "line"
        -- The indicator sprite is center-anchored, so shift it half a charge
        -- ahead to cover exactly the committed lane.
        if offset == nil then offset = distance * 0.5 end
    end

    return size_x or pattern.range or 80,
        size_y or pattern.width or 40,
        offset or 0,
        shape or "line"
end

--- Spawn a telegraph for an attack pattern.
-- @param boss Boss instance (needs .facing, .id)
-- @param pattern Attack pattern table. Respected fields:
--          telegraph_shape ("line"|"circle"|"cone"), telegraph_color,
--          telegraph_size, telegraph_offset, telegraph_sound
-- @param duration Override telegraph time (defaults to pattern.telegraph_time).
-- @return opaque telegraph handle (id or nil)
function M.begin(boss, pattern, duration)
    if not boss or not pattern then return nil end
    duration = duration or pattern.telegraph_time or Defaults.telegraph_time
    if duration <= 0 then return nil end

    -- Audio cue
    if pattern.telegraph_sound then
        SafeSound.play(pattern.telegraph_sound)
    end

    -- Visual cue via factory (optional; not every boss ships a telegraph factory)
    local pos = pcall(go.get_position) and go.get_position() or vmath.vector3()
    local facing = boss.facing or 1
    local size_x, size_y, offset, shape = telegraph_geometry(pattern)
    local spawn_pos = vmath.vector3(pos.x + offset * facing, pos.y, (pos.z or 0) + 0.05)

    local props = {
        shape = shape,
        duration = duration,
        size_x = size_x,
        size_y = size_y,
        facing = facing,
        color_r = (pattern.telegraph_color and pattern.telegraph_color.x) or 1.0,
        color_g = (pattern.telegraph_color and pattern.telegraph_color.y) or 0.2,
        color_b = (pattern.telegraph_color and pattern.telegraph_color.z) or 0.2,
        color_a = (pattern.telegraph_color and pattern.telegraph_color.w) or 0.5,
    }
    local ok, id = pcall(factory.create, TELEGRAPH_FACTORY, spawn_pos, nil, props)
    if not ok then
        -- Factory missing — degrade to screen-shake only (still provides
        -- a visual cue that an attack is incoming).
        if Feedback and Feedback.screen_shake then
            pcall(Feedback.screen_shake, 0.2 * duration, 1.0)
        end
        return nil
    end

    -- Subtle shake near the end of telegraph to reinforce imminent hit.
    if Feedback and Feedback.screen_shake then
        pcall(Feedback.screen_shake, 0.15 * duration, 0.8)
    end
    return id
end

M._telegraph_geometry = telegraph_geometry

--- Cancel a live telegraph (if attack was interrupted).
function M.cancel(handle)
    if handle then pcall(go.delete, handle) end
end

return M
