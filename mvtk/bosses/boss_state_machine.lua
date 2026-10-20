--- Boss State Machine
-- Manages boss AI states and transitions
-- Handles state logic for boss behavior
--
-- @module boss_state_machine

local Util = require "mvtk.core.util"
-- Telegraphs and movement are core encounter behavior. Literal requires are
-- necessary here so Defold's dependency scanner bundles both Lua modules.
local Telegraph = require "mvtk.bosses.boss_telegraph"
local Invulnerability = Util.require_module("mvtk.combat.invulnerability")
local BossAnimations = Util.require_module("mvtk.bosses.boss_animations")
local MovementStrategies = require "mvtk.bosses.movement_strategies"
local SafeSound = require "mvtk.audio.safe_sound"

local function anim(boss, key)
    -- Core state-machine animations (idle/death) must play something even if
    -- the user hasn't mapped them, so use the key-fallback variant here.
    -- Code paths that care about "was this authored?" should call
    -- BossAnimations.resolve directly and branch on nil.
    if BossAnimations and BossAnimations.resolve_or_key then
        return BossAnimations.resolve_or_key(boss, key)
    end
    if BossAnimations and BossAnimations.resolve then
        return BossAnimations.resolve(boss, key) or key
    end
    return key
end

local M = {}

local function boss_label(boss)
    if type(boss) ~= "table" then
        return "boss"
    end
    local boss_data = type(boss.boss_data) == "table" and boss.boss_data or nil
    return tostring(boss.id or boss.boss_id or (boss_data and boss_data.id) or "boss")
end

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.bosses and _Dbg.bosses.manager then
        _orig_print(...)
    end
end

-- Defaults are sourced from developer/config/boss_defaults.lua so users can
-- tune them without editing code. Hard-coded fallbacks only kick in if the
-- config file is missing entirely.
local Defaults = Util.require_config("developer.config.boss_defaults", {
    chase_speed = 120,
    attack_range = 150,
    min_chase_distance = 80,
    telegraph_time = 0.5,
    attack_duration = 1.0,
    attack_interval_min = 2.0,
    attack_interval_max = 4.0,
    idle_deadman_seconds = 8.0,
})

-- Ask the Invulnerability system to hold the flag for `duration` seconds.
-- Used during phase transitions and the defeated state so the flag flips back
-- automatically — setting boss_data.invulnerable directly gets overwritten on
-- the next frame by boss.script's Invulnerability.update() sync.
local function set_invulnerable(boss, duration, reason)
    if not (boss and boss.boss_data) then return end
    if Invulnerability and Invulnerability.start then
        Invulnerability.start(boss.boss_data, duration or 0, reason or "state_machine")
    else
        boss.boss_data.invulnerable = true
    end
end

--- Boss states
M.STATES = {
    IDLE = "idle",
    MOVING = "moving",
    ATTACKING = "attacking",
    TRANSITIONING = "transitioning",
    STUNNED = "stunned",
    DEFEATED = "defeated",
}

--- Create a new state machine instance
-- @param boss Boss instance
-- @return State machine instance
function M.create(boss)
    local sm = {
        boss = boss,
        current_state = M.STATES.IDLE,
        previous_state = nil,
        state_time = 0,
        state_data = {},
    }

    setmetatable(sm, {__index = M})

    -- Call enter function for initial state
    local enter_func = sm["enter_" .. sm.current_state]
    if enter_func then
        enter_func(sm)
    end

    return sm
end

--- Update state machine
-- @param dt Delta time
function M:update(dt)
    self.state_time = self.state_time + dt

    -- Execute current state logic
    local state_func = self["state_" .. self.current_state]
    if state_func then
        state_func(self, dt)
    end
end

--- Change to a new state
-- @param new_state State to change to
-- @param state_data Optional data for the new state
function M:change_state(new_state, state_data)
    if self.current_state == new_state then
        return
    end

    -- Exit current state
    local exit_func = self["exit_" .. self.current_state]
    if exit_func then
        exit_func(self)
    end

    -- Change state
    self.previous_state = self.current_state
    self.current_state = new_state
    self.state_time = 0
    self.state_data = state_data or {}

    print(string.format("[BOSS_SM] %s: %s -> %s", boss_label(self.boss), self.previous_state, self.current_state))

    -- Enter new state
    local enter_func = self["enter_" .. new_state]
    if enter_func then
        enter_func(self)
    end
end

--- Check if in a specific state
-- @param state State to check
-- @return true if in that state
function M:is_state(state)
    return self.current_state == state
end

--- Get current state
-- @return Current state
function M:get_state()
    return self.current_state
end

--[[============================================================================
    IDLE STATE
==============================================================================]]

function M:enter_idle()
    print(string.format("[BOSS_SM] %s entered IDLE", boss_label(self.boss)))
    self.state_data.idle_timer = 0
end

function M:state_idle(dt)
    self.state_data.idle_timer = self.state_data.idle_timer + dt

    -- Check if should attack
    local current_phase = self.boss:get_current_phase()
    if not current_phase then
        -- Debug: log why we can't attack
        if not self.state_data.logged_no_phase then
            print("[BOSS_SM] WARNING: No current phase - boss cannot attack!")
            print("[BOSS_SM] phase_controller exists:", self.boss.phase_controller ~= nil)
            self.state_data.logged_no_phase = true
        end
        return
    end

    -- Use the same profile-aware metric that stops movement. A grounded boss
    -- can have a different root Y from the player even when both are visibly
    -- standing on the same floor.
    local distance_to_player = MovementStrategies.attack_distance(self.boss, current_phase)
    local config = self.boss.config or {}
    local attack_range = (current_phase and current_phase.attack_range)
        or config.attack_range
        or Defaults.attack_range
    local in_attack_range = distance_to_player <= attack_range

    -- Dispatch per-phase movement. Strategy handles position + animation;
    -- falls back to ground_chase when no profile is set.
    if MovementStrategies and MovementStrategies.run then
        MovementStrategies.run(self.boss, current_phase, Defaults, dt)
    end

    -- Attack interval bookkeeping.
    local min_interval = current_phase.attack_interval and current_phase.attack_interval.min or 2.0
    local max_interval = current_phase.attack_interval and current_phase.attack_interval.max or 4.0
    if not self.state_data.next_attack_time then
        self.state_data.next_attack_time = math.random() * (max_interval - min_interval) + min_interval
    end

    if self.state_data.idle_timer >= self.state_data.next_attack_time and in_attack_range then
        local attack = self.boss:select_attack()
        if attack then
            self:change_state(M.STATES.ATTACKING, {attack = attack})
        else
            self.state_data.idle_timer = 0
            self.state_data.next_attack_time = math.random() * (max_interval - min_interval) + min_interval
        end
    end

    -- Face player unless the active phase locks facing.
    local facing_lock = current_phase and current_phase.facing_lock == true
    if not facing_lock and self.boss.face_player then
        self.boss:face_player()
    end
end

function M:exit_idle()
    self.state_data.idle_timer = nil
    self.state_data.next_attack_time = nil
end

--[[============================================================================
    MOVING STATE
==============================================================================]]

function M:enter_moving()
    print(string.format("[BOSS_SM] %s entered MOVING", boss_label(self.boss)))
end

function M:state_moving(dt)
    -- Check if reached target position
    if self.state_data.target_position then
        local pos = self.boss:get_position()
        local distance = vmath.length(self.state_data.target_position - pos)

        if distance <= (self.state_data.stop_distance or 10) then
            -- Reached destination
            if self.state_data.on_arrival then
                self.state_data.on_arrival()
            else
                self:change_state(M.STATES.IDLE)
            end
        else
            -- Keep moving
            local move_speed = (self.state_data.speed or 100) * (self.boss.boss_data and self.boss.boss_data.speed_multiplier or 1.0)
            self.boss:move_toward(self.state_data.target_position, move_speed, dt)
        end
    else
        -- No target, return to idle
        self:change_state(M.STATES.IDLE)
    end
end

function M:exit_moving()
    self.state_data.target_position = nil
    self.state_data.on_arrival = nil
end

--[[============================================================================
    ATTACKING STATE
==============================================================================]]

function M:enter_attacking()
    local attack = self.state_data.attack
    print(string.format("[BOSS_SM] %s entered ATTACKING: %s", boss_label(self.boss), attack or "unknown"))

    self.state_data.attack_timer = 0
    self.state_data.attack_started = false
    self.state_data.attack_finished = false

    -- Spawn attack telegraph immediately so the wind-up is visible.
    -- Resolve the pattern once for the whole attack. A phase can change while
    -- an attack is winding up; keeping one snapshot ensures the telegraph,
    -- execution, frame updates, and cancellation all use the same authored
    -- Tiled values.
    local pattern = self.boss.get_attack_pattern and self.boss:get_attack_pattern(attack)
    self.state_data.pattern = pattern
    if Telegraph and pattern then
        -- Lock the warning to the same horizontal facing the attack will use.
        -- This is especially important for charges, whose telegraph spans the
        -- full committed lane before movement begins.
        if self.boss.face_player then
            self.boss:face_player()
        end
        if pattern.type == "charge" then
            self.boss._attack_facing_locked = self.boss.facing or 1
        end
        local tele_time = pattern.telegraph_time or Defaults.telegraph_time
        self.state_data.telegraph_handle = Telegraph.begin(self.boss, pattern, tele_time)
    end
end

function M:state_attacking(dt)
    local attack = self.state_data.attack
    if not attack then
        self:change_state(M.STATES.IDLE)
        return
    end

    self.state_data.attack_timer = self.state_data.attack_timer + dt

    -- Use the pattern snapshot captured on entry so phase changes during a
    -- telegraph cannot change the attack underneath the player.
    local pattern = self.state_data.pattern
    if not pattern then
        print(string.format("[BOSS_SM] Unknown attack pattern: %s", attack))
        self:change_state(M.STATES.IDLE)
        return
    end

    -- Telegraph phase
    local telegraph_time = pattern.telegraph_time or Defaults.telegraph_time
    if not self.state_data.attack_started and self.state_data.attack_timer >= telegraph_time then
        -- Execute attack
        self.boss:execute_attack(attack, pattern)
        self.state_data.attack_started = true
    end

    -- Stateful attacks (such as charges) own their movement and hit checks
    -- while ATTACKING. Fire-and-forget attacks simply return false here.
    local runtime_active = false
    if self.state_data.attack_started and self.boss.update_attack then
        runtime_active = self.boss:update_attack(attack, pattern, dt) and true or false
    end

    -- Attack duration
    local attack_duration = pattern.duration or Defaults.attack_duration
    local total_time = telegraph_time + attack_duration

    if self.state_data.attack_timer >= total_time and not runtime_active then
        -- Attack finished
        self:change_state(M.STATES.IDLE)
    end
end

function M:exit_attacking()
    local attack = self.state_data.attack
    local pattern = self.state_data.pattern
    if pattern and self.boss.cancel_attack then
        self.boss:cancel_attack(attack, pattern)
    end
    self.boss._attack_facing_locked = nil
    if Telegraph and self.state_data.telegraph_handle then
        -- Telegraph self-despawns via its own duration, but cancel defensively
        -- so interrupted attacks don't leave stale visuals behind.
        Telegraph.cancel(self.state_data.telegraph_handle)
        self.state_data.telegraph_handle = nil
    end
    self.state_data.attack = nil
    self.state_data.attack_timer = nil
    self.state_data.attack_started = nil
    self.state_data.attack_finished = nil
    self.state_data.pattern = nil
end

--[[============================================================================
    TRANSITIONING STATE (Phase Changes)
==============================================================================]]

function M:enter_transitioning()
    local transition = self.state_data.transition
    print(string.format("[BOSS_SM] %s entered TRANSITIONING", boss_label(self.boss)))

    self.state_data.transition_timer = 0

    -- Make boss invulnerable during transition
    if transition and transition.invulnerable then
        self.boss.invulnerable = true
    end

    -- Play transition animation
    if transition and transition.animation then
        self.boss:play_animation(transition.animation)
    end

    -- Camera shake
    if transition and transition.camera_shake then
        local shake = transition.camera_shake
        -- Integration point for camera shake
        print(string.format("[BOSS_SM] Camera shake: intensity=%d, duration=%.1f",
            shake.intensity or 10, shake.duration or 2.0))
    end

    -- Play sound
    if self.boss.config and self.boss.config.audio and self.boss.config.audio.phase_change then
        SafeSound.play(self.boss.config.audio.phase_change)
    end
end

function M:state_transitioning(dt)
    local transition = self.state_data.transition
    if not transition then
        self:change_state(M.STATES.IDLE)
        return
    end

    self.state_data.transition_timer = self.state_data.transition_timer + dt

    local duration = transition.duration or 2.0

    if self.state_data.transition_timer >= duration then
        -- Transition complete
        self.boss.invulnerable = false
        self:change_state(M.STATES.IDLE)
    end
end

function M:exit_transitioning()
    self.boss.invulnerable = false
    self.state_data.transition = nil
    self.state_data.transition_timer = nil
end

--[[============================================================================
    STUNNED STATE
==============================================================================]]

function M:enter_stunned()
    print(string.format("[BOSS_SM] %s entered STUNNED", boss_label(self.boss)))
    self.state_data.stun_timer = 0
end

function M:state_stunned(dt)
    self.state_data.stun_timer = self.state_data.stun_timer + dt

    local stun_duration = self.state_data.stun_duration or 2.0

    if self.state_data.stun_timer >= stun_duration then
        -- Stun ended
        self:change_state(M.STATES.IDLE)
    end

    -- Visual feedback (flashing, stars, etc.)
    if math.floor(self.state_data.stun_timer * 10) % 2 == 0 then
        -- Flash sprite
    end
end

function M:exit_stunned()
    self.state_data.stun_timer = nil
    self.state_data.stun_duration = nil
end

--[[============================================================================
    DEFEATED STATE
==============================================================================]]

function M:enter_defeated()
    print(string.format("[BOSS_SM] %s entered DEFEATED", boss_label(self.boss)))

    self.state_data.death_timer = 0
    self.boss.invulnerable = true

    -- Play death animation through the shared boss animation contract.
    self.boss:play_animation(anim(self.boss, "death"))

    -- Play death sound
    if self.boss.config and self.boss.config.audio and self.boss.config.audio.death then
        SafeSound.play(self.boss.config.audio.death)
    end

    -- Camera shake
    print("[BOSS_SM] Death camera shake")

    -- Notify manager
    if self.boss.on_defeat then
        self.boss:on_defeat()
    end
end

function M:state_defeated(dt)
    self.state_data.death_timer = self.state_data.death_timer + dt

    -- Wait for death animation/sequence to finish
    local death_duration = 3.0

    if self.state_data.death_timer >= death_duration then
        -- Death sequence complete
        -- Boss game object will be deleted by manager
    end
end

function M:exit_defeated()
    -- No exit from defeated state
end

--[[============================================================================
    UTILITY
==============================================================================]]

--- Force a state change (used by boss script)
-- @param state New state
-- @param data Optional state data
function M:force_state(state, data)
    self:change_state(state, data)
end

--- Check if boss can be damaged in current state
-- @return true if vulnerable
function M:is_vulnerable()
    return not (
        self.current_state == M.STATES.TRANSITIONING or
        self.current_state == M.STATES.DEFEATED or
        self.boss.invulnerable
    )
end

--- Get time in current state
-- @return State time in seconds
function M:get_state_time()
    return self.state_time
end

return M
