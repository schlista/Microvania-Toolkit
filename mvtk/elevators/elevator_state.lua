-- mvtk/elevators/elevator_state.lua
-- Pure, deterministic two-stop elevator state machine.
--
-- This module deliberately knows nothing about Defold, streamed rooms, game
-- objects, or timers.  The persistent elevator manager supplies readiness and
-- obstruction facts, performs the room handoff, and consumes the emitted
-- events.  Positions are plain { x, y, z } tables so this module can be tested
-- with ordinary Lua.

local Util = require "mvtk.core.util"

local M = {}

M.STOP_BOTTOM = "bottom"
M.STOP_TOP = "top"

M.STATE_IDLE = "idle"
M.STATE_WAITING_READY = "waiting_ready"
M.STATE_STARTING = "starting"
M.STATE_CLOSING = "closing"
M.STATE_MOVING = "moving"
M.STATE_HANDOFF = "handoff"
M.STATE_OPENING = "opening"
M.STATE_DWELLING = "dwelling"
M.STATE_FAULTED = "faulted"

local Machine = {}
Machine.__index = Machine

local EPSILON = 0.000001

local function finite_number(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    return n
end

local function copy_position(position)
    position = position or {}
    return {
        x = finite_number(position.x) or 0,
        y = finite_number(position.y) or 0,
        z = finite_number(position.z) or 0,
    }
end

local function normalize_stop(value)
    if value == 1 then return M.STOP_BOTTOM end
    if value == 2 then return M.STOP_TOP end
    if value == nil then return nil end

    local text = Util.hash_text(value)
    if not text then return nil end
    text = text:lower():gsub("[%s%-]+", "_")

    if text == "bottom" or text == "lower" or text == "down" or text == "floor_1" then
        return M.STOP_BOTTOM
    end
    if text == "top" or text == "upper" or text == "up" or text == "floor_2" then
        return M.STOP_TOP
    end
    return nil
end

local function other_stop(stop)
    if stop == M.STOP_BOTTOM then return M.STOP_TOP end
    if stop == M.STOP_TOP then return M.STOP_BOTTOM end
    return nil
end

local function append_events(target, source)
    for i = 1, #(source or {}) do
        target[#target + 1] = source[i]
    end
end

local function positions_equal(a, b)
    return math.abs((a.x or 0) - (b.x or 0)) <= EPSILON
        and math.abs((a.y or 0) - (b.y or 0)) <= EPSILON
        and math.abs((a.z or 0) - (b.z or 0)) <= EPSILON
end

local function lerp_position(a, b, t)
    return {
        x = a.x + (b.x - a.x) * t,
        y = a.y + (b.y - a.y) * t,
        z = a.z + (b.z - a.z) * t,
    }
end

local function build_motion_profile(distance, speed, acceleration, deceleration)
    local profile = {
        distance = distance,
        max_speed = speed,
        acceleration = acceleration,
        deceleration = deceleration,
        d_accel = 0,
        d_decel = 0,
        t_accel = 0,
        t_cruise = distance / speed,
        t_decel = 0,
        duration = distance / speed,
    }
    if acceleration <= EPSILON or deceleration <= EPSILON then
        return profile
    end

    local d_accel = speed * speed / (2 * acceleration)
    local d_decel = speed * speed / (2 * deceleration)
    local peak_speed = speed
    if d_accel + d_decel > distance then
        peak_speed = math.sqrt((2 * distance) / ((1 / acceleration) + (1 / deceleration)))
        d_accel = peak_speed * peak_speed / (2 * acceleration)
        d_decel = peak_speed * peak_speed / (2 * deceleration)
    end

    profile.max_speed = peak_speed
    profile.d_accel = d_accel
    profile.d_decel = d_decel
    profile.t_accel = peak_speed / acceleration
    profile.t_decel = peak_speed / deceleration
    profile.t_cruise = math.max(0, distance - d_accel - d_decel) / peak_speed
    profile.duration = profile.t_accel + profile.t_cruise + profile.t_decel
    return profile
end

local function profile_distance_at(profile, elapsed)
    local t = math.max(0, math.min(profile.duration, elapsed))
    if profile.t_accel > 0 and t < profile.t_accel then
        return 0.5 * profile.acceleration * t * t
    end
    if t < profile.t_accel + profile.t_cruise then
        return profile.d_accel + profile.max_speed * (t - profile.t_accel)
    end
    if profile.t_decel > 0 then
        local remaining_t = profile.duration - t
        return profile.distance - 0.5 * profile.deceleration * remaining_t * remaining_t
    end
    return math.min(profile.distance, profile.max_speed * t)
end

local function profile_time_at_distance(profile, distance)
    local d = math.max(0, math.min(profile.distance, distance))
    if profile.t_accel > 0 and d < profile.d_accel then
        return math.sqrt((2 * d) / profile.acceleration)
    end
    local cruise_end = profile.distance - profile.d_decel
    if d <= cruise_end and profile.max_speed > EPSILON then
        return profile.t_accel + ((d - profile.d_accel) / profile.max_speed)
    end
    if profile.t_decel > 0 then
        local remaining_d = profile.distance - d
        return profile.duration - math.sqrt((2 * remaining_d) / profile.deceleration)
    end
    return d / profile.max_speed
end

local function validation_error(message)
    return false, message
end

function M.normalize_stop(value)
    return normalize_stop(value)
end

function M.other_stop(value)
    return other_stop(normalize_stop(value))
end

function M.validate(config)
    if type(config) ~= "table" then
        return validation_error("elevator config must be a table")
    end

    local bottom = config.bottom
    local top = config.top
    if type(bottom) ~= "table" or type(top) ~= "table" then
        return validation_error("elevator requires bottom and top stop positions")
    end

    local bx, by = finite_number(bottom.x), finite_number(bottom.y)
    local tx, ty = finite_number(top.x), finite_number(top.y)
    if not bx or not by or not tx or not ty then
        return validation_error("elevator stop coordinates must be finite numbers")
    end
    if ty <= by then
        return validation_error("top stop must be above bottom stop")
    end

    local shaft_tolerance = finite_number(config.shaft_tolerance) or 0.5
    if shaft_tolerance < 0 then
        return validation_error("shaft_tolerance cannot be negative")
    end
    if math.abs(tx - bx) > shaft_tolerance then
        return validation_error("vertical elevator stops must share the same X coordinate")
    end

    local speed = finite_number(config.speed) or 96
    if speed <= 0 then
        return validation_error("elevator speed must be greater than zero")
    end

    for _, name in ipairs({ "close_time", "open_time", "start_delay", "endpoint_wait",
        "acceleration", "deceleration" }) do
        local value = finite_number(config[name]) or 0
        if value < 0 then
            return validation_error(name .. " cannot be negative")
        end
    end

    local timeout = finite_number(config.ready_timeout)
    if timeout ~= nil and timeout <= 0 then
        return validation_error("ready_timeout must be greater than zero")
    end

    local seam_y = finite_number(config.seam_y) or ((by + ty) * 0.5)
    if seam_y <= by or seam_y >= ty then
        return validation_error("seam_y must lie strictly between the two stops")
    end


    if config.handoff_points ~= nil then
        if type(config.handoff_points) ~= "table" or #config.handoff_points == 0 then
            return validation_error("handoff_points must contain at least one shaft seam")
        end
        local previous = by
        for _, point in ipairs(config.handoff_points) do
            local y = finite_number(type(point) == "table" and point.y or point)
            if not y or y <= previous or y >= ty then
                return validation_error("handoff_points must be strictly increasing between the stops")
            end
            previous = y
        end
    end

    if not normalize_stop(config.home_stop or M.STOP_BOTTOM) then
        return validation_error("home_stop must be 'bottom' or 'top'")
    end
    if config.initial_stop ~= nil and not normalize_stop(config.initial_stop) then
        return validation_error("initial_stop must be 'bottom' or 'top'")
    end

    return true
end

local function make_event(self, event_type, fields)
    local event = fields or {}
    event.type = event_type
    event.generation = self.generation
    event.state = self.state
    event.position = copy_position(event.position or self.position)
    return event
end

local function stop_position(self, stop)
    if stop == M.STOP_TOP then
        return self.top
    end
    return self.bottom
end

local function clear_trip(self)
    self.from_stop = nil
    self.target_stop = nil
    self.wait_elapsed = 0
    self.phase_elapsed = 0
    self.move_elapsed = 0
    self.trip_handoffs = {}
    self.handoff_cursor = 1
end

function M.new(config)
    local valid, err = M.validate(config)
    if not valid then
        return nil, err
    end

    local bottom = copy_position(config.bottom)
    local top = copy_position(config.top)
    local home_stop = normalize_stop(config.home_stop) or M.STOP_BOTTOM
    local initial_stop = normalize_stop(config.initial_stop) or home_stop
    local self = setmetatable({
        bottom = bottom,
        top = top,
        home_stop = home_stop,
        speed = finite_number(config.speed) or 96,
        acceleration = finite_number(config.acceleration) or 0,
        deceleration = finite_number(config.deceleration) or 0,
        start_delay = finite_number(config.start_delay) or 0,
        close_time = finite_number(config.close_time) or 0.25,
        open_time = finite_number(config.open_time) or 0.25,
        endpoint_wait = finite_number(config.endpoint_wait) or 0,
        ready_timeout = finite_number(config.ready_timeout) or 5,
        seam_y = finite_number(config.seam_y) or ((bottom.y + top.y) * 0.5),
        handoff_points = {},
        state = M.STATE_IDLE,
        current_stop = initial_stop,
        position = copy_position(stop_position({ bottom = bottom, top = top }, initial_stop)),
        generation = math.max(0, math.floor(finite_number(config.generation) or 0)),
        from_stop = nil,
        target_stop = nil,
        wait_elapsed = 0,
        phase_elapsed = 0,
        move_elapsed = 0,
        trip_handoffs = {},
        handoff_cursor = 1,
        fault_reason = nil,
    }, Machine)

    for _, point in ipairs(config.handoff_points or { self.seam_y }) do
        self.handoff_points[#self.handoff_points + 1] = finite_number(type(point) == "table" and point.y or point)
    end

    return self
end

function Machine:is_idle()
    return self.state == M.STATE_IDLE
end

function Machine:is_busy()
    return self.state ~= M.STATE_IDLE and self.state ~= M.STATE_FAULTED
end

function Machine:get_position()
    return copy_position(self.position)
end

function Machine:snapshot()
    return {
        state = self.state,
        current_stop = self.current_stop,
        from_stop = self.from_stop,
        target_stop = self.target_stop,
        home_stop = self.home_stop,
        position = copy_position(self.position),
        generation = self.generation,
        wait_elapsed = self.wait_elapsed,
        phase_elapsed = self.phase_elapsed,
        move_elapsed = self.move_elapsed,
        handoff_cursor = self.handoff_cursor,
        handoff_count = #self.trip_handoffs,
        fault_reason = self.fault_reason,
    }
end

function Machine:request(target_stop)
    local target = normalize_stop(target_stop)
    if not target then
        return false, "invalid_stop", {}
    end
    if self.state == M.STATE_FAULTED then
        return false, "faulted", {}
    end
    if self.state ~= M.STATE_IDLE then
        return false, "busy", {}
    end
    if target == self.current_stop then
        return false, "already_at_stop", {}
    end

    self.generation = self.generation + 1
    self.from_stop = self.current_stop
    self.target_stop = target
    self.state = M.STATE_WAITING_READY
    self.wait_elapsed = 0
    self.phase_elapsed = 0
    self.move_elapsed = 0
    self.trip_handoffs = {}
    if self.from_stop == M.STOP_BOTTOM then
        for i = 1, #self.handoff_points do
            self.trip_handoffs[#self.trip_handoffs + 1] = self.handoff_points[i]
        end
    else
        for i = #self.handoff_points, 1, -1 do
            self.trip_handoffs[#self.trip_handoffs + 1] = self.handoff_points[i]
        end
    end
    self.handoff_cursor = 1
    self.fault_reason = nil

    return true, "accepted", {
        make_event(self, "trip_requested", {
            from_stop = self.from_stop,
            target_stop = self.target_stop,
        }),
    }
end

function Machine:fail(reason)
    reason = tostring(reason or "failed")
    local invalidated_generation = self.generation
    local preserve_position = self.state == M.STATE_MOVING or self.state == M.STATE_HANDOFF

    self.generation = self.generation + 1
    self.fault_reason = reason

    if preserve_position then
        self.state = M.STATE_FAULTED
    else
        -- Readiness/door failures occur while the cabin is still at its source.
        -- Opening failures occur after it has safely reached the destination.
        if self.state == M.STATE_OPENING and self.target_stop then
            self.current_stop = self.target_stop
        end
        self.position = copy_position(stop_position(self, self.current_stop))
        self.state = M.STATE_IDLE
        clear_trip(self)
    end

    return {
        make_event(self, "trip_failed", {
            reason = reason,
            invalidated_generation = invalidated_generation,
            faulted = self.state == M.STATE_FAULTED,
        }),
    }
end

function Machine:reset(stop, reason)
    local resolved = normalize_stop(stop) or self.home_stop
    local invalidated_generation = self.generation
    self.generation = self.generation + 1
    self.current_stop = resolved
    self.position = copy_position(stop_position(self, resolved))
    self.state = M.STATE_IDLE
    self.fault_reason = nil
    clear_trip(self)

    return {
        make_event(self, "reset", {
            reason = tostring(reason or "reset"),
            stop = resolved,
            invalidated_generation = invalidated_generation,
        }),
    }
end

function Machine:cancel(reason, options)
    options = options or {}
    if options.reset_home then
        return self:reset(self.home_stop, reason or "cancelled")
    end
    if options.stop then
        return self:reset(options.stop, reason or "cancelled")
    end
    if self.state == M.STATE_MOVING or self.state == M.STATE_HANDOFF then
        -- Never teleport a live passenger out of a shaft merely because a
        -- trigger was released.  A deliberate death/world reset passes
        -- reset_home and may snap after passengers have been cleared.
        return self:fail(reason or "cancelled_in_motion")
    end
    return self:reset(self.current_stop, reason or "cancelled")
end

function Machine:confirm_handoff(success, reason)
    if self.state ~= M.STATE_HANDOFF then
        return false, "not_waiting_for_handoff", {}
    end
    if success == false then
        return false, tostring(reason or "handoff_failed"), self:fail(reason or "handoff_failed")
    end

    self.state = M.STATE_MOVING
    self.handoff_cursor = self.handoff_cursor + 1
    return true, "accepted", {
        make_event(self, "room_handoff", {
            from_stop = self.from_stop,
            target_stop = self.target_stop,
            handoff_index = self.handoff_cursor - 1,
            handoff_count = #self.trip_handoffs,
        }),
    }
end

local function emit_move(self, events, old_position)
    if positions_equal(old_position, self.position) then
        return
    end
    events[#events + 1] = make_event(self, "moved", {
        from_position = copy_position(old_position),
        position = copy_position(self.position),
        dx = self.position.x - old_position.x,
        dy = self.position.y - old_position.y,
        dz = self.position.z - old_position.z,
        progress = math.abs(self.position.y - stop_position(self, self.from_stop).y)
            / math.abs(self.top.y - self.bottom.y),
    })
end

-- Advance deterministically by dt seconds.
--
-- Returns a result table with events and remaining_dt.  Movement intentionally
-- stops at the room seam and returns unconsumed time.  The manager must perform
-- the streamed-room handoff, call confirm_handoff(), then feed remaining_dt
-- back into update().  This prevents a large frame from skipping the seam.
function Machine:update(dt, environment)
    environment = environment or {}
    local remaining = math.max(0, finite_number(dt) or 0)
    local events = {}
    local guard = 0

    while guard < 16 do
        guard = guard + 1

        if self.state == M.STATE_IDLE or self.state == M.STATE_FAULTED or self.state == M.STATE_HANDOFF then
            break
        end

        if self.state == M.STATE_WAITING_READY then
            if environment.destination_failed then
                append_events(events, self:fail(environment.failure_reason or "destination_failed"))
                break
            elseif environment.destination_ready then
                self.state = self.start_delay > EPSILON and M.STATE_STARTING or M.STATE_CLOSING
                self.phase_elapsed = 0
                events[#events + 1] = make_event(self, "destination_ready", {
                    target_stop = self.target_stop,
                })
                if self.state == M.STATE_STARTING then
                    events[#events + 1] = make_event(self, "start_delay", {
                        stop = self.from_stop,
                        duration = self.start_delay,
                    })
                else
                    events[#events + 1] = make_event(self, "doors_closing", {
                        stop = self.from_stop,
                    })
                end
            else
                if remaining <= EPSILON then break end
                local until_timeout = self.ready_timeout - self.wait_elapsed
                local consumed = math.min(remaining, math.max(0, until_timeout))
                self.wait_elapsed = self.wait_elapsed + consumed
                remaining = remaining - consumed
                if self.wait_elapsed + EPSILON >= self.ready_timeout then
                    append_events(events, self:fail("destination_ready_timeout"))
                end
                break
            end

        elseif self.state == M.STATE_STARTING then
            local needed = math.max(0, self.start_delay - self.phase_elapsed)
            if needed > EPSILON and remaining <= EPSILON then break end
            local consumed = math.min(remaining, needed)
            self.phase_elapsed = self.phase_elapsed + consumed
            remaining = remaining - consumed
            if self.phase_elapsed + EPSILON >= self.start_delay then
                self.state = M.STATE_CLOSING
                self.phase_elapsed = 0
                events[#events + 1] = make_event(self, "doors_closing", { stop = self.from_stop })
            else
                break
            end

        elseif self.state == M.STATE_CLOSING then
            if environment.blocked then
                append_events(events, self:fail(environment.block_reason or "door_obstructed"))
                break
            end

            local needed = math.max(0, self.close_time - self.phase_elapsed)
            if needed > EPSILON and remaining <= EPSILON then break end
            local consumed = math.min(remaining, needed)
            self.phase_elapsed = self.phase_elapsed + consumed
            remaining = remaining - consumed

            if self.phase_elapsed + EPSILON >= self.close_time then
                self.state = M.STATE_MOVING
                self.phase_elapsed = 0
                self.move_elapsed = 0
                events[#events + 1] = make_event(self, "departed", {
                    from_stop = self.from_stop,
                    target_stop = self.target_stop,
                })
            else
                break
            end

        elseif self.state == M.STATE_MOVING then
            if environment.blocked then
                append_events(events, self:fail(environment.block_reason or "shaft_obstructed"))
                break
            end

            local from_position = stop_position(self, self.from_stop)
            local target_position = stop_position(self, self.target_stop)
            local distance = math.abs(target_position.y - from_position.y)
            local profile = build_motion_profile(distance, self.speed, self.acceleration, self.deceleration)
            local next_handoff_y = self.trip_handoffs[self.handoff_cursor]
            local boundary_distance = next_handoff_y
                and math.abs(next_handoff_y - from_position.y) or distance
            local boundary_time = profile_time_at_distance(profile, boundary_distance)
            local needed = math.max(0, boundary_time - self.move_elapsed)

            if needed > EPSILON and remaining <= EPSILON then break end
            local consumed = math.min(remaining, needed)
            local old_position = copy_position(self.position)
            self.move_elapsed = math.min(profile.duration, self.move_elapsed + consumed)
            remaining = remaining - consumed
            local travelled = profile_distance_at(profile, self.move_elapsed)
            self.position = lerp_position(from_position, target_position, travelled / distance)
            emit_move(self, events, old_position)

            if self.move_elapsed + EPSILON >= boundary_time then
                if next_handoff_y then
                    self.position.y = next_handoff_y
                    self.state = M.STATE_HANDOFF
                    events[#events + 1] = make_event(self, "room_handoff_required", {
                        from_stop = self.from_stop,
                        target_stop = self.target_stop,
                        handoff_index = self.handoff_cursor,
                        handoff_count = #self.trip_handoffs,
                    })
                    break
                end

                self.position = copy_position(target_position)
                self.state = M.STATE_OPENING
                self.phase_elapsed = 0
                events[#events + 1] = make_event(self, "arrived", {
                    stop = self.target_stop,
                })
                events[#events + 1] = make_event(self, "doors_opening", {
                    stop = self.target_stop,
                })
            else
                break
            end

        elseif self.state == M.STATE_OPENING then
            local needed = math.max(0, self.open_time - self.phase_elapsed)
            if needed > EPSILON and remaining <= EPSILON then break end
            local consumed = math.min(remaining, needed)
            self.phase_elapsed = self.phase_elapsed + consumed
            remaining = remaining - consumed

            if self.phase_elapsed + EPSILON >= self.open_time then
                self.current_stop = self.target_stop
                local completed_stop = self.current_stop
                if self.endpoint_wait > EPSILON then
                    self.state = M.STATE_DWELLING
                    self.phase_elapsed = 0
                    events[#events + 1] = make_event(self, "endpoint_wait", {
                        stop = completed_stop,
                        duration = self.endpoint_wait,
                    })
                else
                    self.state = M.STATE_IDLE
                    clear_trip(self)
                    events[#events + 1] = make_event(self, "trip_completed", {
                        stop = completed_stop,
                    })
                end
            else
                break
            end

        elseif self.state == M.STATE_DWELLING then
            local needed = math.max(0, self.endpoint_wait - self.phase_elapsed)
            if needed > EPSILON and remaining <= EPSILON then break end
            local consumed = math.min(remaining, needed)
            self.phase_elapsed = self.phase_elapsed + consumed
            remaining = remaining - consumed
            if self.phase_elapsed + EPSILON >= self.endpoint_wait then
                local completed_stop = self.current_stop
                self.state = M.STATE_IDLE
                clear_trip(self)
                events[#events + 1] = make_event(self, "trip_completed", { stop = completed_stop })
            else
                break
            end
        end
    end

    return {
        events = events,
        remaining_dt = remaining,
        snapshot = self:snapshot(),
        position = copy_position(self.position),
    }
end

return M
