-- mvtk/combat/attack_executor.lua
-- Attack timeline executor for the player.

local Util = require "mvtk.core.util"
local CombatConfig = require "mvtk.combat.config"
local DamagePayload = require "mvtk.combat.damage_payload"
local CombatFeedback = require "mvtk.combat.combat_feedback"
local C = require "mvtk.core.constants"
local SwingRegistry = require "mvtk.combat.swing_registry"
local SpineVisual = require "mvtk.player.spine_visual"

local M = {}

local BASE_HITBOX_WIDTH = 120
local BASE_HITBOX_HEIGHT = 100
-- The circle hitbox prototype's collision shape has radius 50 (see
-- developer/game/attacks/melee_hitbox_circle.collisionobject). Scale is
-- computed against this so width/height -> radius mapping stays consistent.
local BASE_HITBOX_RADIUS = 50

local function number_or(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function resolve_duration(window)
    return number_or(window.duration, 0)
end

local function total_duration(attack)
    local timeline = attack.timeline or {}
    local finish = number_or(timeline.startup, 0) + number_or(timeline.recovery, 0)
    for _, window in ipairs(timeline.active_windows or {}) do
        local start_t = number_or(window.start, 0)
        finish = math.max(finish, start_t + resolve_duration(window))
    end
    return finish
end

local function cooldown_key(attack)
    return attack.cooldown_group or attack.attack_id or attack.input
end

local function clear_hitboxes(self)
    local combat = self._combat
    if not combat then
        return
    end
    for id, _ in pairs(combat.active_hitboxes or {}) do
        pcall(go.delete, id)
        combat.active_hitboxes[id] = nil
    end
    self._attack_hitbox_id = nil
    -- Drop the active swing's dedup entry so the registry doesn't accumulate.
    -- Subsequent windows in the same attack will allocate a fresh id.
    if combat.current_swing_id then
        SwingRegistry.clear_swing(combat.current_swing_id)
        combat.current_swing_id = nil
    end
end

local function begin_follow(id, follow)
    if not id or type(follow) ~= "table" then
        return
    end
    if follow.mode == "bone" and follow.bone and follow.spine_url then
        pcall(msg.post, id, hash("set_follow_bone"), {
            bone = follow.bone,
            spine_url = follow.spine_url,
            offset = follow.offset or vmath.vector3(),
        })
        return
    end
    pcall(msg.post, id, hash("set_follow_owner"), {
        owner = follow.owner,
        offset = follow.offset or vmath.vector3(),
        active = true,
    })
end

local function follow_spec(self, hitbox)
    local anchor = hitbox.anchor or {}
    local sprite_offset = anchor.sprite_offset or anchor.offset or { x = 0, y = 0 }
    local spine_offset = anchor.spine_offset or anchor.offset or { x = 0, y = 0 }
    local facing = (self.facing or 1) >= 0 and 1 or -1
    local use_spine = self._anim_is_spine and anchor.spine_bone
    if use_spine then
        return {
            mode = "bone",
            bone = anchor.spine_bone,
            spine_url = SpineVisual.resolve(),
            offset = vmath.vector3(
                facing * number_or(spine_offset.x, 0),
                number_or(spine_offset.y, 0),
                0
            ),
        }
    end
    return {
        mode = "owner",
        owner = go.get_id(),
        offset = vmath.vector3(
            facing * number_or(sprite_offset.x, 0),
            number_or(sprite_offset.y, 0),
            0
        ),
    }
end

local function attack_position(self, follow)
    local pos = go.get_position()
    local offset = (follow and follow.offset) or vmath.vector3()
    return pos + offset
end

local function projectile_dir(self, attack, projectile)
    local facing = (self.facing or 1) >= 0 and 1 or -1
    local movement = attack.movement or {}
    local dx = number_or(projectile.dir_x, number_or(movement.projectile_dir_x, facing))
    local dy = number_or(projectile.dir_y, number_or(movement.projectile_dir_y, 0))
    return dx, dy, facing
end

local function to_url(value)
    if value == nil then return msg.url() end
    if type(value) == "userdata" then
        local ok, u = pcall(msg.url, value)
        if ok then return u end
    end
    return msg.url()
end

local function make_payload(self, attack, event_def, extras)
    local payload = DamagePayload.build(Util.merge({
        source_actor = go.get_id(),
        source_attack = attack.attack_id,
        reaction_type = event_def.reaction_type or attack.reaction_type,
        attack_type = event_def.action_tag or attack.attack_type,
        parryable = event_def.parryable,
        stun_t = event_def.stun_t,
    }, extras or {}))
    return payload
end

local function spawn_melee_hitbox(self, attack, hitbox, duration)
    local follow = follow_spec(self, hitbox)
    local p = attack_position(self, follow)
    local swing_id_str = self._combat and self._combat.current_swing_id or nil
    local is_circle = hitbox.shape == "circle"
    local debug_w_raw = number_or(hitbox.width, BASE_HITBOX_WIDTH)
    local debug_h_raw = number_or(hitbox.height, BASE_HITBOX_HEIGHT)
    local debug_radius_raw = number_or(hitbox.radius, debug_w_raw * 0.5)
    local scale
    if is_circle then
        local s = math.max(0.1, debug_radius_raw / BASE_HITBOX_RADIUS)
        scale = vmath.vector3(s, s, 1)
    else
        scale = vmath.vector3(
            math.max(0.1, debug_w_raw / BASE_HITBOX_WIDTH),
            math.max(0.1, debug_h_raw / BASE_HITBOX_HEIGHT),
            1
        )
    end
    local payload = make_payload(self, attack, hitbox, {
        amount = hitbox.damage,
        kx = number_or(hitbox.kx, number_or(hitbox.knockback, 0) * ((self.facing or 1) >= 0 and 1 or -1)),
        ky = number_or(hitbox.ky, 0),
    })
    local fac_url = is_circle and C.URL.FACTORY.melee_circle or C.URL.FACTORY.melee
    local ok, id = pcall(factory.create, fac_url, p, nil, {
        lifetime = duration,
        damage = payload.amount,
        knockback = number_or(hitbox.knockback, 0),
        dir = (self.facing or 1) >= 0 and 1 or -1,
        stun_t = payload.stun_t,
        on_hit_msg = hitbox.on_hit_msg or "",
        attack_type = payload.attack_type,
        source_attack = payload.source_attack or "",
        source_actor = to_url(payload.source_actor),
        parryable = payload.parryable,
        reaction_type = payload.reaction_type or "",
        kx = payload.kx,
        ky = payload.ky,
        debug_w = debug_w_raw,
        debug_h = debug_h_raw,
        debug_shape = hitbox.shape or "box",
        debug_radius = debug_radius_raw,
        swing_id = swing_id_str or "",
    }, scale)
    if ok and id then
        begin_follow(id, follow)
        pcall(msg.post, id, hash("set_owner"), { owner = go.get_id() })
        self._combat.active_hitboxes[id] = true
        self._attack_hitbox_id = id
    end
end

local function spawn_projectile(self, attack, projectile)
    local offset = projectile.offset or { x = 24, y = 18 }
    local facing = (self.facing or 1) >= 0 and 1 or -1
    local anchor = go.get_position()
    local oy = number_or(offset.y, 18)
    -- origin sits on the shooter at muzzle height; the projectile sweeps
    -- origin -> spawn on its first frame so a wall the shooter is touching
    -- stops the shot instead of letting it spawn on the far side.
    local origin = vmath.vector3(anchor.x, anchor.y + oy, anchor.z)
    local p = vmath.vector3(anchor.x + facing * number_or(offset.x, 24), anchor.y + oy, anchor.z)
    local dx, dy, dir = projectile_dir(self, attack, projectile)
    local payload = make_payload(self, attack, projectile, {
        amount = projectile.damage,
        kx = number_or(projectile.kx, 60 * dir),
        ky = number_or(projectile.ky, 0),
    })
    pcall(factory.create, C.URL.FACTORY.projectile, p, nil, {
        dir = dir,
        dir_x = dx,
        dir_y = dy,
        speed = number_or(projectile.speed, 1200),
        lifetime = number_or(projectile.lifetime, 1.5),
        damage = payload.amount,
        attack_type = payload.attack_type,
        source_attack = payload.source_attack or "",
        source_actor = to_url(payload.source_actor),
        parryable = payload.parryable,
        reaction_type = payload.reaction_type or "",
        kx = payload.kx,
        ky = payload.ky,
        stun_t = payload.stun_t,
        origin_x = origin.x,
        origin_y = origin.y,
        probe_origin = true,
    }, 1)
end

local function spawn_window(self, attack, window)
    local duration = math.max(0.04, resolve_duration(window))
    -- Allocate a per-active-window swing_id used by all hitboxes in this
    -- window. mvtk.combat.swing_registry uses it to dedup hits across
    -- overlapping sibling hitboxes (e.g. tip-damage + body-damage). Each new
    -- active window gets a fresh id, so a multi-hit attack still hits the
    -- same enemy once per window.
    if self._combat then
        self._combat.swing_counter = (self._combat.swing_counter or 0) + 1
        self._combat.current_swing_id = string.format(
            "%s:%s:%d",
            Util.hash_to_stable_string(go.get_id()),
            tostring(attack.attack_id or "?"),
            self._combat.swing_counter
        )
    end
    for _, hitbox in ipairs(window.hitboxes or {}) do
        spawn_melee_hitbox(self, attack, hitbox, duration)
    end
    if window.projectile then
        spawn_projectile(self, attack, window.projectile)
    end
end

local function apply_start_movement(self, attack)
    local movement = attack.movement or {}
    if movement.impulse_x or movement.impulse_y then
        self.vx = (self.vx or 0) + number_or(movement.impulse_x, 0) * ((self.facing or 1) >= 0 and 1 or -1)
        self.vy = (self.vy or 0) + number_or(movement.impulse_y, 0)
    end
end

local function update_attack_motion(self, attack)
    local movement = attack.movement or {}
    if movement.hold_vy_min ~= nil and (self.vy or 0) < movement.hold_vy_min then
        self.vy = movement.hold_vy_min
    end
    if movement.hold_vy_max ~= nil and (self.vy or 0) > movement.hold_vy_max then
        self.vy = movement.hold_vy_max
    end
end

local function current_attack(self)
    return self._combat and self._combat.current or nil
end

function M.init(self, hooks)
    self._combat = {
        hooks = hooks or {},
        current = nil,
        queued_attack_id = nil,
        cooldowns = {},
        active_hitboxes = {},
        counter_window_t = 0,
        counter_target = nil,
    }
end

function M.is_active(self)
    return current_attack(self) ~= nil
end

function M.can_cancel_to(self, action_name)
    local current = current_attack(self)
    if not current then
        return true
    end
    if action_name == "parry" and not CombatConfig.feature_enabled("parry", true) then
        return false
    end
    if not CombatConfig.feature_enabled("attack_cancels", true) then
        return false
    end
    for _, window in ipairs(current.attack.cancel_windows or {}) do
        local start_t = number_or(window.start, 0)
        local finish_t = number_or(window.finish, current.total_duration)
        if current.t >= start_t and current.t <= finish_t then
            local actions = window.actions or {}
            if actions[action_name] then
                return true
            end
        end
    end
    return false
end

function M.can_queue_combo(self, intent)
    local current = current_attack(self)
    if not current then
        return false
    end
    if not CombatConfig.feature_enabled("combo_chaining", true) then
        return false
    end
    local combo_links = current.attack.combo_links or {}
    local next_id = combo_links[intent]
    if not next_id then
        return false
    end
    if intent == "heavy" and not CombatConfig.feature_enabled("mixed_finishers", true) then
        return false
    end
    local combo_window = current.attack.combo_window or {}
    local start_t = number_or(combo_window.start, current.total_duration - math.max(0.08, number_or(current.attack.timeline and current.attack.timeline.recovery, 0)))
    local finish_t = start_t + number_or(combo_window.duration, 0.35)
    return current.t >= start_t and current.t <= finish_t
end

local function start_attack(self, attack, ctx)
    clear_hitboxes(self)
    if attack.state == "counter" then
        self._combat.counter_window_t = 0
    end
    local total = total_duration(attack)
    self._combat.current = {
        attack = attack,
        t = 0,
        total_duration = total,
        spawned_windows = {},
    }
    self._combat.queued_attack_id = nil
    self._attack = {
        elapsed = 0,
        ground = ctx and ctx.grounded or false,
        attack_id = attack.attack_id,
    }
    apply_start_movement(self, attack)
    if self._combat.hooks and self._combat.hooks.play_attack_animation then
        self._combat.hooks.play_attack_animation(self, attack)
    end
    if attack.sfx and attack.sfx.start then
        CombatFeedback.play_sfx(attack.sfx.start)
    end
end

local function resolve_attack(self, attack_id, ctx)
    return CombatConfig.resolve_attack(attack_id)
end

local function attack_ready(self, attack)
    local key = cooldown_key(attack)
    local cooldown = self._combat.cooldowns[key] or 0
    return cooldown <= 0
end

function M.request(self, intent, ctx)
    local combat = self._combat
    if not combat then
        return false
    end

    if combat.counter_window_t > 0 then
        ctx = Util.merge(ctx or {}, { counter_window = true })
    end

    local current = current_attack(self)
    if current and M.can_queue_combo(self, intent) then
        combat.queued_attack_id = current.attack.combo_links[intent]
        return true
    end
    if current then
        return false
    end

    local attack_id = CombatConfig.resolve_attack_for_input(intent, ctx or {})
    if not attack_id then
        return false
    end
    local attack = resolve_attack(self, attack_id, ctx)
    if not attack or not attack_ready(self, attack) then
        return false
    end
    start_attack(self, attack, ctx or {})
    return true
end

function M.update(self, dt, ctx)
    local combat = self._combat
    if not combat then
        return
    end

    for key, value in pairs(combat.cooldowns) do
        combat.cooldowns[key] = math.max(0, number_or(value, 0) - dt)
    end
    combat.counter_window_t = math.max(0, number_or(combat.counter_window_t, 0) - dt)
    if combat.counter_window_t <= 0 then
        combat.counter_target = nil
    end

    local current = combat.current
    if not current then
        return
    end

    current.t = current.t + dt
    if self._attack then
        self._attack.elapsed = current.t
    end

    update_attack_motion(self, current.attack)

    for index, window in ipairs(current.attack.timeline.active_windows or {}) do
        local start_t = number_or(window.start, 0)
        local finish_t = start_t + resolve_duration(window)
        local active = current.t >= start_t and current.t < finish_t
        if active and not current.spawned_windows[index] then
            current.spawned_windows[index] = true
            spawn_window(self, current.attack, window)
        elseif (not active) and current.spawned_windows[index] == true and current.t >= finish_t then
            current.spawned_windows[index] = "done"
            clear_hitboxes(self)
        end
    end

    if current.t < current.total_duration then
        return
    end

    clear_hitboxes(self)
    combat.cooldowns[cooldown_key(current.attack)] = number_or(current.attack.cooldown, 0)
    local queued_attack_id = combat.queued_attack_id
    combat.current = nil
    self._attack = nil

    if queued_attack_id then
        local next_attack = resolve_attack(self, queued_attack_id, ctx or {})
        combat.queued_attack_id = nil
        if next_attack and attack_ready(self, next_attack) then
            start_attack(self, next_attack, ctx or {})
        end
    end
end

function M.on_animation_done(self)
    local current = current_attack(self)
    if not current then
        self._attack = nil
        clear_hitboxes(self)
        return
    end
    if current.t >= current.total_duration then
        clear_hitboxes(self)
        self._combat.current = nil
        self._attack = nil
    end
end

function M.cancel(self)
    if not self._combat then
        return
    end
    clear_hitboxes(self)
    self._combat.current = nil
    self._combat.queued_attack_id = nil
    self._attack = nil
end

function M.open_counter_window(self, duration, attacker_url)
    if not self._combat then
        return
    end
    if not CombatConfig.feature_enabled("parry_counter", true) then
        return
    end
    self._combat.counter_window_t = math.max(number_or(self._combat.counter_window_t, 0), number_or(duration, 0))
    self._combat.counter_target = attacker_url or self._combat.counter_target
end

return M
