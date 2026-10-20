-- mvtk/debug/player_debug_bridge.lua
-- Broadcasts player data to debug overlay
-- Call from player.script update() to send debug info

local Time = require "mvtk.core.time"
local ParrySystem = require "mvtk.player.parry_system"

local M = {}

-- Track last update time to avoid spamming messages
local last_update_time = 0
local update_rate = 0.05 -- Send updates 20 times per second

local function get_overlay_url()
    local go_url = msg.url("main:/debug_overlay")
    if go.exists(go_url) then
        return msg.url("main:/debug_overlay#debug_overlay")
    end
    return nil
end

local function combat_phase(player_self)
    local combat = player_self._combat
    local current = combat and combat.current or nil
    if not current or not current.attack then
        return nil
    end

    local attack = current.attack
    local t = current.t or 0
    local timeline = attack.timeline or {}
    local startup = tonumber(timeline.startup) or 0
    if t < startup then
        return "startup"
    end

    for _, window in ipairs(timeline.active_windows or {}) do
        local start_t = tonumber(window.start) or 0
        local finish_t = start_t + (tonumber(window.duration) or 0)
        if t >= start_t and t < finish_t then
            return "active"
        end
    end

    return "recovery"
end

-- Send player data to debug overlay
function M.send_player_data(player_self)
    local current_time = Time.gettime()

    -- Throttle updates
    if current_time - last_update_time < update_rate then
        return
    end
    last_update_time = current_time

    -- Gather player data
    local data = {
        position = player_self.pos or go.get_position(),
        velocity = vmath.vector3(player_self.vx or 0, player_self.vy or 0, 0),
        state = player_self.current_state or player_self._current_state or "unknown",
        combat_attack = player_self._attack and player_self._attack.attack_id or nil,
        combat_attack_t = player_self._attack and player_self._attack.elapsed or 0,
        combat_attack_phase = combat_phase(player_self),
        combat_queued_attack = player_self._combat and player_self._combat.queued_attack_id or nil,
        combat_counter_t = player_self._combat and (player_self._combat.counter_window_t or 0) or 0,
        parry_window_t = ParrySystem.get_parry_time_remaining and ParrySystem.get_parry_time_remaining() or 0,
        parry_cooldown_t = ParrySystem.get_cooldown_remaining and ParrySystem.get_cooldown_remaining() or 0,
        parry_last_perfect = ParrySystem.was_last_parry_perfect and ParrySystem.was_last_parry_perfect() or false,
        health = player_self.health or 0,
        max_health = player_self.max_health or 0,
        energy = player_self.energy or 0,
        max_energy = player_self.max_energy or 0,
        stamina = player_self.stamina or 0,
        max_stamina = player_self.max_stamina or 100,
        grounded = player_self.grounded or false,
        room = player_self.current_room or "unknown",
    }

    local overlay_url = get_overlay_url()
    if overlay_url then
        pcall(msg.post, overlay_url, hash("debug_player_data"), data)
    end
end

return M
