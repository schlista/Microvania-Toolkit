-- Kinematic grappling for the existing player movement/collision pipeline.
-- Tiled surfaces are static, baked room objects; this module creates no objects.
local M = {}

local function setting(actions, config, key, fallback)
    local value = config and config[key]
    if value == nil then value = actions and actions[key] end
    if value == nil then return fallback end
    return value
end

function M.direction(input, facing, actions, config)
    input = input or {}
    local deadzone = setting(actions, config, "aim_deadzone", 0.3)
    local x, y = input.move_x or 0, input.move_y or 0
    if math.abs(x) < deadzone then x = 0 end
    if math.abs(y) < deadzone then y = 0 end
    y = math.max(0, y)
    if x == 0 and y == 0 and setting(actions, config, "default_aim", "up") == "forward" then
        x = facing and facing ~= 0 and facing or 1
    end
    if x == 0 then return 0, 1 end
    local angle = math.rad(setting(actions, config, "diagonal_angle_deg", 45))
    return (x > 0 and 1 or -1) * math.cos(angle), math.sin(angle)
end

-- Tagged strips may overlap the terrain they mark, but cannot catch through it.
function M.pick_target(hits, ray_length, opts)
    if ray_length <= 0 then return nil end
    table.sort(hits, function(a, b) return a.fraction < b.fraction end)
    local first = hits[1]
    if not first then return nil end
    local limit = first.fraction + (opts.tolerance_px or 0) / ray_length
    for _, hit in ipairs(hits) do
        if hit.fraction > limit then break end
        if hit.group == opts.grapple_group and hit.normal.y < 0.5 then return hit, "surface" end
    end
    if opts.targets == "ceilings" and opts.latch[first.group] then
        if first.normal.y <= -opts.ceiling_normal_min then return first, "ceiling" end
        if opts.allow_walls and math.abs(first.normal.x) >= opts.wall_normal_min then return first, "wall" end
    end
    return nil
end

function M.clear(self)
    self._grapple_active = false
    self._grapple_anchor = nil
    self._grapple_target = nil
    self._grapple_rope_length = nil
    self._grapple_room_id = nil
    self._grapple_launch_length = nil
    self._grapple_step_vx, self._grapple_step_vy = nil, nil
    self._grapple_carry_t = 0
    self._grapple_flight = false
    self._grapple_recast_t = 0
    self._grapple_elapsed = 0
    self._grapple_just_released = false
    self._control_locked = false
end

function M.release(self, input, actions, config, kind)
    if not self._grapple_active then return false end
    kind = kind or "let_go"
    M.clear(self)
    self._grapple_release_kind = kind
    if kind ~= "impact" then
        -- The rising arc after letting go is swing momentum, not a jump: the
        -- early-jump-release gravity must not cut it short (cleared at apex).
        self._grapple_flight = true
        self._grapple_carry_t = setting(actions, config, "release_carry_time", 0.35)
        self._climb_reattach_lock_t = math.max(self._climb_reattach_lock_t or 0,
            setting(actions, config, "ladder_grab_delay_s", 0.25))
    end
    if kind == "let_go" then
        local momentum = setting(actions, config, "release_momentum_mult", 1)
        self.vx, self.vy = (self.vx or 0) * momentum, (self.vy or 0) * momentum
    end
    local boost = kind == "let_go" and setting(actions, config, "release_boost_px", 0) or 0
    if boost ~= 0 then
        local x = input and input.move_x or 0
        local vx = self.vx or 0
        local dir
        if vx ~= 0 and math.abs(vx) >= 0.25 * setting(actions, config, "swing_max_speed", 1200) then
            dir = vx > 0 and 1 or -1
        else
            dir = x ~= 0 and (x > 0 and 1 or -1) or (self.facing and self.facing ~= 0 and self.facing or 1)
        end
        self.vx = (self.vx or 0) + dir * boost
    end
    if kind == "let_go" then
        self.vy = (self.vy or 0) + setting(actions, config, "release_up_boost_px", 0)
    end
    -- Movement for the release frame consumes these exact velocities before
    -- ordinary air steering resumes. Jump release does not spend an air jump.
    self._grapple_just_released = kind ~= "impact"
    return true
end

function M.release_on_jump(actions, config)
    return setting(actions, config, "release_on_jump", true)
end

function M.attach(self, position, hit, actions, config, grounded)
    local normal = hit.normal or { x = 0, y = 0 }
    local half_w = self.collider_half_width or self._cfg.collider_half_width or 0
    local half_h = self.collider_half_height or self._cfg.collider_half_height or 0
    local clearance = math.abs(normal.x) * half_w + math.abs(normal.y) * half_h
        + setting(actions, config, "surface_clearance_px", 4)
    local dx, dy = position.x - hit.position.x, position.y - hit.position.y
    local distance = math.sqrt(dx * dx + dy * dy)
    local min_length = math.max(clearance, setting(actions, config, "min_rope_length_px", clearance))
    local desired_length = setting(actions, config, "rope_length_px", 0)
    local launch_length
    if grounded then
        local gap = hit.position.y - position.y - setting(actions, config, "ground_clearance_px", 16)
        if gap < min_length then return false end
        launch_length = math.min(distance, gap)
    end
    self._grapple_anchor = vmath.vector3(hit.position)
    self._grapple_target = vmath.vector3(hit.position.x + normal.x * clearance,
        hit.position.y + normal.y * clearance, position.z)
    self._grapple_rope_length = grounded and distance or
        (desired_length > 0 and math.max(min_length, desired_length) or math.max(min_length, distance))
    self._grapple_launch_length = launch_length
    self._grapple_carry_t = 0
    self._grapple_flight = false
    self._grapple_recast_t = 0
    self._grapple_release_kind = nil
    self._grapple_min_length = min_length
    self._grapple_elapsed = 0
    self._grapple_just_released = false
    self._grapple_active = true
    self.grounded = false
    self._coyote_t, self._jump_buffer_t = 0, 0
    self._control_locked = true
    self._on_wall, self._wall_sliding = false, false
    self._dash_t, self._slide_t, self._roll_t, self._backdash_t = 0, 0, 0, 0
    self._ledge_hanging, self._ledge_climbing, self._ledge_kinematic = false, false, false
    return true
end

function M.rope_state(hit, ray_len, anchor_dist, tol)
    if not hit then return "lost" end
    if hit.fraction * ray_len < anchor_dist - tol then return "lost" end
    return "ok"
end

function M.on_contacts(self, collision, actions, config)
    if collision and (collision.grounded or (collision.wall_contact or 0) ~= 0) then
        self._grapple_carry_t = 0
    end
    if not self._grapple_active or not collision or
        not setting(actions, config, "release_on_impact", true) or
        (self._grapple_elapsed or 0) < setting(actions, config, "attach_grace_s", 0.12) or
        self._grapple_launch_length then return false end
    local vx, vy = self._grapple_step_vx or 0, self._grapple_step_vy or 0
    local wall = collision.wall_contact or 0
    local speed = setting(actions, config, "impact_release_speed", 150)
    if collision.grounded or (wall ~= 0 and vx * wall > 0 and math.abs(vx) >= speed) or
        (collision.ceiling_contact and vy >= speed) then
        return M.release(self, nil, actions, config, "impact")
    end
    return false
end

-- Returns an optional rate override; nil leaves normal acceleration intact.
function M.carry_steering(self, target_vx, accelerating, decel, actions, config)
    if (self._grapple_carry_t or 0) <= 0 or self.grounded or self._on_wall then return target_vx end
    local vx = self.vx or 0
    if target_vx == 0 or (target_vx * vx > 0 and math.abs(target_vx) <= math.abs(vx)) then
        return vx, 0
    end
    if target_vx * vx < 0 then
        return target_vx, decel * setting(actions, config, "release_carry_brake", 0.35)
    end
    return target_vx
end

-- Carry float replaces ordinary ascent/descent gravity rules. Fast-fall is
-- applied afterward by player_state, so Down still gives deliberate control.
function M.release_gravity(self, g_base, actions, config)
    if self._grapple_active or self.grounded or self._on_wall
        or (self._grapple_carry_t or 0) <= 0 then return nil end
    local kind = self._grapple_release_kind
    if kind ~= "let_go" and kind ~= "room" and kind ~= "lost" then return nil end
    return g_base * setting(actions, config, "release_gravity_mult", 0.6)
end

-- Returns velocity whose next integration step stays within a taut rope. The
-- rope can go slack, so jumping/moving toward the anchor remains natural.
function M.swing_velocity(position, anchor, length, vx, vy, dt, input_x, gravity, acceleration, drag, max_speed, speed_limit)
    if dt <= 0 then return vx, vy end
    local speed = math.sqrt(vx * vx + vy * vy)
    if max_speed > 0 and speed < max_speed then
        local pumped = vx + input_x * acceleration * dt
        -- Only the input contribution is limited. Preserve vertical energy.
        local horizontal_cap = math.sqrt(math.max(0, max_speed * max_speed - vy * vy))
        vx = math.max(-horizontal_cap, math.min(horizontal_cap, pumped))
    end
    vy = vy - math.abs(gravity) * dt
    local damping = math.exp(-math.max(0, drag) * dt)
    vx, vy = vx * damping, vy * damping
    speed_limit = speed_limit and speed_limit > 0 and speed_limit or 3 * max_speed
    speed = math.sqrt(vx * vx + vy * vy)
    if speed_limit > 0 and speed > speed_limit then
        vx, vy = vx * speed_limit / speed, vy * speed_limit / speed
    end
    local dx = position.x + vx * dt - anchor.x
    local dy = position.y + vy * dt - anchor.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance > length and distance > 0 then
        local next_x = anchor.x + dx * length / distance
        local next_y = anchor.y + dy * length / distance
        vx, vy = (next_x - position.x) / dt, (next_y - position.y) / dt
    end
    speed = math.sqrt(vx * vx + vy * vy)
    if speed_limit > 0 and speed > speed_limit then
        vx, vy = vx * speed_limit / speed, vy * speed_limit / speed
    end
    return vx, vy
end

function M.update(self, dt, input, actions, config)
    input = input or {}
    if self._grapple_just_released then
        self._grapple_just_released = false
        return true
    end
    if not self._grapple_active or not self._grapple_anchor then return false end
    if (self._stun_t or 0) > 0 then M.clear(self); return false end
    self._grapple_elapsed = (self._grapple_elapsed or 0) + dt
    local max_duration = setting(actions, config, "max_duration", 0)
    -- Keyboard and gamepad holds are aggregated by input_controller. A single
    -- source's release edge must not drop a hook another source still holds.
    local button_released = input.grapple_held == false
        or (input.grapple_held == nil and input.grapple_up)
    local stay_hooked = setting(actions, config, "stay_hooked", false)
    local release_press = stay_hooked and input.grapple_down
    if release_press then
        -- player.script runs PSTATE.update (and this update) before its cast.
        -- Attachment happens after this block, so its first press cannot let
        -- go. Consume a later press on the shared frame input to prevent a
        -- same-frame re-hook or a missed-cast hold-retry window.
        input.grapple_down = false
    end
    if release_press or (not stay_hooked and button_released) or
        (input.jump_down and M.release_on_jump(actions, config)) or
        (max_duration > 0 and self._grapple_elapsed >= max_duration) then
        M.release(self, input, actions, config, "let_go")
        self._grapple_just_released = false
        return true
    end
    local position = self.pos or go.get_position()
    if setting(actions, config, "mode", "pull") == "swing" then
        local settling = false
        if self._grapple_launch_length then
            -- Keep launch protection through the final inward integration step.
            -- Settle on the next update, once the player has reached the arc.
            settling = self._grapple_rope_length <= self._grapple_launch_length
            self._grapple_rope_length = math.max(self._grapple_launch_length,
                self._grapple_rope_length - math.max(0, setting(actions, config, "launch_reel_speed", 1400)) * dt)
        elseif setting(actions, config, "reel_enabled", false) then
            local reel_speed = math.max(0, setting(actions, config, "reel_speed", 0))
            local range = setting(actions, config, "range_px", 300)
            self._grapple_rope_length = math.max(self._grapple_min_length,
                math.min(range, self._grapple_rope_length - (input.move_y or 0) * reel_speed * dt))
        end
        self.vx, self.vy = M.swing_velocity(position, self._grapple_anchor,
            self._grapple_rope_length, self.vx or 0, self.vy or 0, dt,
            input.move_x or 0, self._cfg.gravity or 0,
            setting(actions, config, "swing_acceleration", 0),
            setting(actions, config, "swing_drag", 0),
            setting(actions, config, "swing_max_speed", 0),
            setting(actions, config, "swing_speed_limit", 0))
        if settling then
            local dx, dy = position.x - self._grapple_anchor.x, position.y - self._grapple_anchor.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance <= self._grapple_rope_length + 0.00001 then
                self._grapple_launch_length = nil
                if distance > 0 then
                    local ux, uy = dx / distance, dy / distance
                    local vr = self.vx * ux + self.vy * uy
                    if vr < 0 then self.vx, self.vy = self.vx - vr * ux, self.vy - vr * uy end
                end
            end
        end
    else
        -- Pull mode already lifts toward its arrival point; it has no launch reel.
        self._grapple_launch_length = nil
        local target = self._grapple_target or self._grapple_anchor
        local dx, dy = target.x - position.x, target.y - position.y
        local distance = math.sqrt(dx * dx + dy * dy)
        if distance <= setting(actions, config, "arrival_distance_px", 8) then
            self.vx, self.vy = 0, 0
            if not setting(actions, config, "hold_at_anchor", false) then M.clear(self) end
        elseif dt > 0 then
            -- Clamp the step to avoid oscillating through a ceiling on arrival.
            local speed = math.min(setting(actions, config, "pull_speed", 2000), distance / dt)
            self.vx, self.vy = dx / distance * speed, dy / distance * speed
        end
    end
    self._grapple_step_vx, self._grapple_step_vy = self.vx, self.vy
    self._control_locked = self._grapple_active
    if math.abs(self.vx or 0) > 0.01 then self.facing = self.vx > 0 and 1 or -1 end
    return true
end

function M.draw_rope(self, actions, config)
    -- These modes bypass normal movement, so discard both the old anchor
    -- and any release carry before they can resume ordinary movement.
    if (self._grapple_active or (self._grapple_carry_t or 0) > 0)
        and (self._is_dead or self._in_water or self._in_climb) then
        M.clear(self)
    end
    if not setting(actions, config, "rope_enabled", false) then return end
    local position = self.pos or go.get_position()
    local anchor = self._grapple_active and self._grapple_anchor or position
    local color = setting(actions, config, "rope_color", { 1, 1, 1, 1 })
    go.set("#grapple_rope", "rope_start", vmath.vector4(position.x, position.y,
        position.z + setting(actions, config, "rope_z", 0.15),
        setting(actions, config, "rope_width_px", 3)))
    go.set("#grapple_rope", "rope_end", vmath.vector4(anchor.x, anchor.y, 0,
        self._grapple_active and 1 or 0))
    go.set("#grapple_rope", "tint", vmath.vector4(color[1], color[2], color[3], color[4] or 1))
end

return M
