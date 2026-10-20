--- Phase Controller
-- Manages boss phase transitions and phase-specific behavior
-- Handles health thresholds and phase changes
--
-- @module phase_controller

local Util = require "mvtk.core.util"
local Invulnerability = require "mvtk.combat.invulnerability"
local Feedback = Util.require_module("mvtk.combat.combat_feedback")
local BossArena = Util.require_module("mvtk.bosses.boss_arena")
local BossAnimations = Util.require_module("mvtk.bosses.boss_animations")
local Audio = Util.require_module("mvtk.audio.audio")
local SafeSound = require "mvtk.audio.safe_sound"
local BossUI = require "mvtk.bosses.boss_ui"
local Defaults = Util.require_config("developer.config.boss_defaults", {
    iframes_on_phase_transition = 1.5,
})

local Motion = require "mvtk.bosses.boss_motion"
local M = {}
local Pause = require "mvtk.core.pause"

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.bosses and _Dbg.bosses.phases then
        _orig_print(...)
    end
end

local function resolve_arena_id(boss)
    if not boss then
        return nil
    end
    local config = boss.config or {}
    local data = boss.boss_data or {}
    return config.arena_id or config.arena or data.arena_id or data.arena
end

local TRANSITION_TYPE_ALIASES = {
    power_up = "rage",
    malfunction = "rage",
    final_form = "transform",
}

local function normalize_transition_type(value)
    local transition_type = tostring(value or ""):lower()
    return TRANSITION_TYPE_ALIASES[transition_type] or transition_type
end

local function resolve_transition_animation(boss, animation_name)
    if type(animation_name) ~= "string" or animation_name == "" then
        return animation_name
    end
    if BossAnimations and BossAnimations.resolve_or_key then
        return BossAnimations.resolve_or_key(boss, animation_name)
    end
    return animation_name
end

-- When every phase is authored without a health_range (or with the sentinel
-- -1, -1) evenly split [0, 1] across all phases. Explicit ranges on any
-- phase suppress the auto-split so mixed authoring still works.
function M.derive_phase_bands(phases)
    if not phases or #phases == 0 then return phases end

    local needs_derive = true
    for _, phase in ipairs(phases) do
        local hr = phase.health_range
        if hr and not (hr.min == nil or hr.min == -1 or hr.max == nil or hr.max == -1) then
            needs_derive = false
            break
        end
    end
    if not needs_derive then return phases end

    local n = #phases
    -- Phase 1 covers the top band (1.0 .. (n-1)/n], phase n covers the
    -- bottom (0 .. 1/n]. get_phase_for_health walks the list top-down.
    for i, phase in ipairs(phases) do
        local top = 1.0 - (i - 1) / n
        local bot = 1.0 - i / n
        phase.health_range = { min = bot, max = top }
    end
    return phases
end

--- Create a new phase controller instance
-- @param boss Boss instance
-- @param phases Table of phase definitions
-- @return Phase controller instance
function M.create(boss, phases)
    local pc = {
        boss = boss,
        phases = M.derive_phase_bands(phases or {}),
        current_phase_index = 1,
        previous_phase_index = 0,
        transitioning = false,
        -- Preserve the already-merged preset/instance movement value so a
        -- later phase with no override can restore it after an authored phase.
        base_chase_speed = boss and boss.config and boss.config.chase_speed or nil,
    }

    setmetatable(pc, {__index = M})

    return pc
end

--- Update phase controller
-- @param dt Delta time
function M:update(dt)
    -- Check if should change phase based on health
    self:check_phase_change()
end

--- Check if boss should change phase
function M:check_phase_change()
    if self.transitioning then
        return  -- Already transitioning
    end
    if not (self.boss and self.boss.get_health_percent) then
        return
    end

    local health_percent = self.boss:get_health_percent() or 1.0

    -- Find appropriate phase for current health
    local target_phase_index = self:get_phase_for_health(health_percent)

    if target_phase_index ~= self.current_phase_index then
        -- Phase change needed
        self:transition_to_phase(target_phase_index)
    end
end

--- Get phase index for given health percentage.
-- Tolerant of phases authored without a health_range: a missing range is
-- treated as "this phase covers all hp" (only useful if there is a single
-- phase) so misconfigured data doesn't crash the update loop.
-- @param health_percent Health as percentage (0.0 to 1.0)
-- @return Phase index
function M:get_phase_for_health(health_percent)
    for i, phase in ipairs(self.phases) do
        local hr = phase.health_range
        local min = (hr and hr.min) or 0
        local max = (hr and hr.max) or 1

        if health_percent > min and health_percent <= max then
            return i
        end
    end

    -- Default to last phase if health is 0 or below
    return #self.phases
end

--- Transition to a new phase
-- @param phase_index Index of phase to transition to
function M:transition_to_phase(phase_index)
    if Pause.get() then
        Pause.delay(0, function() self:transition_to_phase(phase_index) end)
        return
    end
    if phase_index < 1 or phase_index > #self.phases then
        print(string.format("[PHASE_CTRL] Invalid phase index: %d", phase_index))
        return
    end

    if phase_index == self.current_phase_index then
        return  -- Already in this phase
    end

    local new_phase = self.phases[phase_index]

    print(string.format("[PHASE_CTRL] %s transitioning: Phase %d -> Phase %d",
        self.boss.id, self.current_phase_index, phase_index))

    -- Store previous phase
    self.previous_phase_index = self.current_phase_index
    self.current_phase_index = phase_index

    -- Execute transition
    if new_phase.transition then
        self:execute_transition(new_phase.transition, phase_index)
    end

    -- Every phase change synchronizes the authored arena mechanics, even
    -- when the phase has no transition animation or delay.
    if self.boss.on_phase_change then
        self.boss:on_phase_change(self.previous_phase_index, phase_index)
    end

    if not new_phase.transition then
        -- No transition defined, instant change
        self:on_phase_complete(phase_index)
    end
end

--- Execute phase transition
-- @param transition Transition configuration
-- @param phase_index Target phase index
function M:execute_transition(transition, phase_index)
    self.transitioning = true

    print(string.format("[PHASE_CTRL] Executing %s transition", transition.type or "default"))

    -- Make the boss invulnerable during the transition so the player can't
    -- burst past a phase while animations play. Duration is configurable per
    -- transition (transition.iframes) with a global default fallback.
    local iframes = transition.iframes or Defaults.iframes_on_phase_transition
    if iframes and iframes > 0 and self.boss.boss_data then
        Invulnerability.start(self.boss.boss_data, iframes, "phase_transition")
    end

    -- Use registered encounter listeners, as defeat notifications do. The
    -- boss manager is a Lua module, not a gameobject message receiver.
    BossUI.send("boss_phase_enter", {
        boss_id = self.boss.id or self.boss.boss_id,
        from_phase = self.previous_phase_index,
        to_phase = phase_index,
        transition_type = transition.type,
    })

    -- Pre-phase telegraph: brief flash + shake so the transition reads.
    if Feedback then
        if Feedback.screen_shake then
            pcall(Feedback.screen_shake, 0.4, 1.4)
        end
        if Feedback.flash then
            pcall(Feedback.flash, { duration = 0.2, color = vmath.vector4(1, 0.8, 0.2, 0.5) })
        end
    end

    -- Put boss in transitioning state
    if self.boss.state_machine then
        self.boss.state_machine:change_state("transitioning", {
            transition = transition,
            target_phase = phase_index,
        })
    end

    -- Schedule transition completion
    local duration = transition.duration or 2.0
    Pause.delay(duration, function()
        self:on_phase_complete(phase_index)
    end)

    -- Execute transition type-specific logic
    local transition_type = normalize_transition_type(transition.type)
    if transition_type == "cutscene" then
        self:execute_cutscene_transition(transition)
    elseif transition_type == "teleport" then
        self:execute_teleport_transition(transition)
    elseif transition_type == "transform" then
        self:execute_transform_transition(transition)
    elseif transition_type == "rage" or transition_type == "desperation" then
        self:execute_rage_transition(transition)
    elseif transition_type == "shield" then
        self:execute_shield_transition(transition)
    end

end

--- Cutscene transition
-- @param transition Transition config
function M:execute_cutscene_transition(transition)
    print("[PHASE_CTRL] Cutscene transition")

    -- Play animation
    if transition.animation then
        self.boss:play_animation(resolve_transition_animation(self.boss, transition.animation))
    end

    -- Camera shake
    if transition.camera_shake then
        if Feedback and Feedback.screen_shake then
            pcall(Feedback.screen_shake,
                transition.camera_shake.duration or transition.duration or 0.5,
                transition.camera_shake.intensity or 1.2)
        end
    end

    if transition.flash and Feedback and Feedback.flash then
        pcall(Feedback.flash, {
            duration = 0.25,
            color = vmath.vector4(1, 1, 1, 0.45),
        })
    end

    if transition.new_music and Audio and Audio.music then
        pcall(Audio.music, transition.new_music, { t = 0.3 })
    end

    -- Could pause player input, zoom camera, etc.
end

-- Validate that a value looks like a vmath.vector3 before handing it to
-- go.set_position (which would crash on a bad type). Accepts the standard
-- userdata vector form only; tables are rejected so callers don't sneak in
-- half-built positions.
local function is_vector3(v)
    return type(v) == "userdata" and pcall(function() return v.x + v.y + v.z end)
end

--- Teleport transition
-- @param transition Transition config
function M:execute_teleport_transition(transition)
    print("[PHASE_CTRL] Teleport transition")
    -- Forced phase changes may originate in a marker's script context.
    local boss_url = self.boss.self_url or go.get_id()

    -- Fade out boss
    Motion.scale(boss_url, vmath.vector3(0, 0, 1), 0.3, "in_cubic", false, function()
        -- Move to new position
        if transition.teleport_to == "arena_center" then
            local arena_center = self.boss:get_arena_center()
            if is_vector3(arena_center) then
                go.set_position(arena_center, boss_url)
            end
        elseif is_vector3(transition.teleport_position) then
            go.set_position(transition.teleport_position, boss_url)
        end

        -- Fade in boss
        Motion.scale(boss_url, vmath.vector3(1, 1, 1), 0.3, "out_cubic")
    end)

    -- Play teleport sound
    if self.boss.config and self.boss.config.audio and self.boss.config.audio.teleport then
        SafeSound.play(self.boss.config.audio.teleport)
    end
end

--- Transform transition
-- @param transition Transition config
function M:execute_transform_transition(transition)
    print("[PHASE_CTRL] Transform transition")

    -- Play transform animation
    if transition.animation then
        self.boss:play_animation(resolve_transition_animation(self.boss, transition.animation))
    end

    if transition.flash and Feedback and Feedback.flash then
        pcall(Feedback.flash, {
            duration = 0.35,
            color = vmath.vector4(0.8, 0.4, 1.0, 0.7),
        })
    end

    if transition.camera_shake and Feedback and Feedback.screen_shake then
        pcall(Feedback.screen_shake,
            transition.camera_shake.duration or transition.duration or 0.6,
            transition.camera_shake.intensity or 1.5)
    end

    local arena_id = resolve_arena_id(self.boss)
    if arena_id and BossArena and BossArena.trigger_arena_effect then
        pcall(BossArena.trigger_arena_effect, arena_id, "flash", {
            color = vmath.vector4(0.8, 0.4, 1.0, 0.7),
            duration = 0.2,
        })
    end

    if transition.new_music and Audio and Audio.music then
        pcall(Audio.music, transition.new_music, { t = 0.4 })
    end
end

--- Rage/desperation transition
-- @param transition Transition config
function M:execute_rage_transition(transition)
    print("[PHASE_CTRL] Rage/desperation transition")

    -- Play enrage animation
    if transition.animation then
        self.boss:play_animation(resolve_transition_animation(self.boss, transition.animation))
    end

    -- Arena effects
    if transition.arena_darkness then
        if BossArena and BossArena.apply_effect then
            pcall(BossArena.apply_effect, "darkness")
        end
    end

    -- Spawn additional hazards
    if transition.spawn_hazards then
        for _, hazard_type in ipairs(transition.spawn_hazards) do
            if BossArena and BossArena.spawn_hazard then
                pcall(BossArena.spawn_hazard, hazard_type)
            end
        end
        local arena_id = resolve_arena_id(self.boss)
        if arena_id and BossArena and BossArena.trigger_arena_effect then
            pcall(BossArena.trigger_arena_effect, arena_id, "hazard_pulse")
        end
    end

    -- Heavy camera shake
    if transition.camera_shake then
        if Feedback and Feedback.screen_shake then
            pcall(Feedback.screen_shake,
                transition.camera_shake.duration or transition.duration or 0.8,
                transition.camera_shake.intensity or 1.8)
        end
    end

    if transition.flash ~= false and Feedback and Feedback.flash then
        pcall(Feedback.flash, {
            duration = 0.3,
            color = vmath.vector4(1.0, 0.2, 0.2, 0.7),
        })
    end

    if transition.new_music and Audio and Audio.music then
        pcall(Audio.music, transition.new_music, { t = 0.3 })
    end
end

--- Shield transition
-- @param transition Transition config
function M:execute_shield_transition(transition)
    print("[PHASE_CTRL] Shield transition")

    -- Activate shield visual
    if transition.animation then
        self.boss:play_animation(resolve_transition_animation(self.boss, transition.animation))
    end

    -- Make invulnerable during charge. Route through Invulnerability so the
    -- flash timer, damage gating, and expiry all run normally — setting the
    -- flag directly bypasses the system and can leave the boss permanently
    -- invulnerable if nothing clears it.
    local shield_time = transition.duration or 2.0
    if self.boss.boss_data then
        Invulnerability.start(self.boss.boss_data, shield_time, "phase_shield")
    end

    if Feedback and Feedback.flash then
        pcall(Feedback.flash, {
            duration = 0.25,
            color = vmath.vector4(0.4, 0.8, 1.0, 0.55),
        })
    end

    if transition.camera_shake and Feedback and Feedback.screen_shake then
        pcall(Feedback.screen_shake,
            transition.camera_shake.duration or transition.duration or 0.4,
            transition.camera_shake.intensity or 1.0)
    end

    local arena_id = resolve_arena_id(self.boss)
    if arena_id and BossArena and BossArena.trigger_arena_effect then
        pcall(BossArena.trigger_arena_effect, arena_id, "flash", {
            color = vmath.vector4(0.4, 0.8, 1.0, 0.55),
            duration = 0.15,
        })
    end

    if transition.new_music and Audio and Audio.music then
        pcall(Audio.music, transition.new_music, { t = 0.3 })
    end
end

--- Called when transition completes
-- @param phase_index Phase that was transitioned to
function M:on_phase_complete(phase_index)
    print(string.format("[PHASE_CTRL] Phase %d transition complete", phase_index))

    self.transitioning = false

    -- Apply phase modifiers
    self:apply_phase_modifiers(phase_index)

    -- Arena hazards/platforms are synced by boss.script.on_phase_change,
    -- which fires earlier in transition_to_phase(). Nothing to do here —
    -- BossArena is imported only so it's discoverable to downstream edits.
    local _ = BossArena

    -- Broadcast phase-complete so listeners (arena controller, UI) can react
    -- after modifiers are applied.
    BossUI.send("boss_phase_complete", {
        boss_id = self.boss.id or self.boss.boss_id,
        phase = phase_index,
    })

    -- Invulnerability is now driven entirely by mvtk.combat.invulnerability:
    -- Invulnerability.start(boss_data, duration, reason) in the transition
    -- and Invulnerability.update(boss_data, dt) in boss.script decay the
    -- timer and clear the flag. No manual reset needed here.

    -- Return boss to combat
    if self.boss.state_machine and self.boss.state_machine:get_state() == "transitioning" then
        self.boss.state_machine:change_state("idle")
    end
end

--- Advance to the next phase (used by weak points, timers, etc.).
function M:advance_phase()
    self:transition_to_phase(self.current_phase_index + 1)
end

--- Apply phase-specific stat modifiers
-- @param phase_index Current phase index
function M:apply_phase_modifiers(phase_index)
    local phase = self.phases[phase_index]
    if not phase then
        return
    end

    -- Speed multiplier
    if phase.speed_multiplier then
        self.boss.speed_multiplier = phase.speed_multiplier
        if self.boss.boss_data then
            self.boss.boss_data.speed_multiplier = phase.speed_multiplier
        end
        print(string.format("[PHASE_CTRL] Speed multiplier: %.1fx", phase.speed_multiplier))
    end

    -- Damage multiplier
    if phase.damage_multiplier then
        self.boss.damage_multiplier = phase.damage_multiplier
        if self.boss.boss_data then
            self.boss.boss_data.damage_multiplier = phase.damage_multiplier
        end
        print(string.format("[PHASE_CTRL] Damage multiplier: %.1fx", phase.damage_multiplier))
    end

    -- chase_speed is an absolute movement value rather than a multiplier.
    -- The phase wins while active; an inherited (-1/missing) value restores
    -- the merged boss preset/Tiled-instance baseline captured at creation.
    if self.boss and self.boss.config then
        local phase_chase_speed = tonumber(phase.chase_speed)
        if phase_chase_speed ~= nil and phase_chase_speed >= 0 then
            self.boss.config.chase_speed = phase_chase_speed
        else
            self.boss.config.chase_speed = self.base_chase_speed
        end
    end

    -- Update attack pool
    if phase.attacks then
        self.boss.available_attacks = phase.attacks
        print(string.format("[PHASE_CTRL] Available attacks: %s", table.concat(phase.attacks, ", ")))
    end
end

--- Get current phase configuration
-- @return Current phase table
function M:get_current_phase()
    return self.phases[self.current_phase_index]
end

--- Get current phase index
-- @return Phase index (1-based)
function M:get_current_phase_index()
    return self.current_phase_index
end

--- Get total number of phases
-- @return Phase count
function M:get_phase_count()
    return #self.phases
end

--- Force phase change (for testing/debugging)
-- @param phase_index Phase to change to
function M:force_phase(phase_index)
    print(string.format("[PHASE_CTRL] Forcing phase change to %d", phase_index))
    self:transition_to_phase(phase_index)
end

--- Check if currently transitioning
-- @return true if transitioning
function M:is_transitioning()
    return self.transitioning
end

--- Get phase name/label
-- @param phase_index Optional phase index (defaults to current)
-- @return Phase name string
function M:get_phase_name(phase_index)
    phase_index = phase_index or self.current_phase_index
    local phase = self.phases[phase_index]

    if phase and phase.name then
        return phase.name
    end

    return string.format("Phase %d", phase_index)
end

return M
