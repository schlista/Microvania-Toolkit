-- mvtk/enemies/ai/bt_actions.lua
-- ============================================================================
-- Behavior Tree Actions - Common action functions
-- ============================================================================
-- Provides reusable action functions for behavior trees.
-- Actions return true (success), false (failure), or STATUS.RUNNING.
--
-- Usage:
--   local Actions = require "mvtk.enemies.ai.bt_actions"
--   local BT = require "mvtk.enemies.ai.behavior_tree"
--
--   BT.action(Actions.move_toward_player(100))

local M = {}

local Detection = require "mvtk.enemies.detection"
local BT = require "mvtk.enemies.ai.behavior_tree"

-- ============================================================================
-- MOVEMENT ACTIONS
-- ============================================================================

--- Move toward player
-- @param speed Movement speed
-- @return Action function
function M.move_toward_player(speed)
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        local direction = vmath.normalize(player_pos - pos)
        local move_speed = speed or context.config.chase_speed or 100

        -- Apply velocity
        context.velocity = context.velocity or vmath.vector3()
        context.velocity.x = direction.x * move_speed
        context.velocity.y = direction.y * move_speed

        -- Update facing
        context.facing = direction.x >= 0 and 1 or -1

        return true
    end
end

--- Move away from player
-- @param speed Movement speed
-- @return Action function
function M.move_away_from_player(speed)
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        local direction = vmath.normalize(pos - player_pos)
        local move_speed = speed or context.config.retreat_speed or 80

        context.velocity = context.velocity or vmath.vector3()
        context.velocity.x = direction.x * move_speed
        context.velocity.y = direction.y * move_speed

        context.facing = direction.x >= 0 and 1 or -1

        return true
    end
end

--- Move toward home/spawn position
-- @param speed Movement speed
-- @param arrival_threshold Distance to consider arrived
-- @return Action function
function M.move_toward_home(speed, arrival_threshold)
    arrival_threshold = arrival_threshold or 20
    return function(context, dt)
        local pos = go.get_position()
        local home = context.home_position or context.spawn_position
        if not home then return true end

        local diff = home - pos
        local distance = vmath.length(diff)

        if distance <= arrival_threshold then
            context.velocity = vmath.vector3()
            return true
        end

        local direction = vmath.normalize(diff)
        local move_speed = speed or context.config.speed or 60

        context.velocity = context.velocity or vmath.vector3()
        context.velocity.x = direction.x * move_speed
        context.velocity.y = direction.y * move_speed

        context.facing = direction.x >= 0 and 1 or -1

        return BT.STATUS.RUNNING
    end
end

--- Patrol horizontally
-- @param speed Movement speed
-- @param distance Patrol distance from home
-- @return Action function
function M.patrol_horizontal(speed, distance)
    distance = distance or 200
    return function(context, dt)
        local pos = go.get_position()
        local home = context.home_position or context.spawn_position or pos

        -- Initialize patrol state
        if not context.blackboard.patrol_dir then
            context.blackboard.patrol_dir = 1
        end

        local move_speed = speed or context.config.speed or 50
        local dir = context.blackboard.patrol_dir

        -- Check boundaries
        local dist_from_home = pos.x - home.x
        if dist_from_home > distance then
            context.blackboard.patrol_dir = -1
            dir = -1
        elseif dist_from_home < -distance then
            context.blackboard.patrol_dir = 1
            dir = 1
        end

        context.velocity = context.velocity or vmath.vector3()
        context.velocity.x = dir * move_speed
        context.velocity.y = 0

        context.facing = dir

        return true
    end
end

--- Stop movement
-- @return Action function
function M.stop()
    return function(context, dt)
        context.velocity = vmath.vector3()
        return true
    end
end

--- Face player
-- @return Action function
function M.face_player()
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        context.facing = player_pos.x > pos.x and 1 or -1
        return true
    end
end

--- Turn around
-- @return Action function
function M.turn_around()
    return function(context, dt)
        context.facing = -(context.facing or 1)
        context.blackboard.patrol_dir = context.facing
        return true
    end
end

--- Dash toward player
-- @param speed Dash speed
-- @param duration Dash duration
-- @return Action function
function M.dash_toward_player(speed, duration)
    speed = speed or 400
    duration = duration or 0.3
    return function(context, dt)
        -- Initialize dash
        if not context.blackboard.dash_timer then
            local pos = go.get_position()
            local player_pos = Detection.get_player_position()
            if not player_pos then return false end

            context.blackboard.dash_timer = 0
            context.blackboard.dash_dir = vmath.normalize(player_pos - pos)
            context.invincible = true
        end

        context.blackboard.dash_timer = context.blackboard.dash_timer + dt

        if context.blackboard.dash_timer >= duration then
            context.blackboard.dash_timer = nil
            context.blackboard.dash_dir = nil
            context.invincible = false
            context.velocity = vmath.vector3()
            return true
        end

        local dir = context.blackboard.dash_dir
        context.velocity = vmath.vector3(dir.x * speed, dir.y * speed, 0)

        return BT.STATUS.RUNNING
    end
end

--- Jump
-- @param force Jump force
-- @return Action function
function M.jump(force)
    force = force or 500
    return function(context, dt)
        if context.grounded then
            context.velocity = context.velocity or vmath.vector3()
            context.velocity.y = force
            context.grounded = false
            return true
        end
        return false
    end
end

--- Jump toward player
-- @param force Jump force
-- @param horizontal_speed Horizontal movement speed
-- @return Action function
function M.jump_toward_player(force, horizontal_speed)
    force = force or 500
    horizontal_speed = horizontal_speed or 150
    return function(context, dt)
        if not context.grounded then return false end

        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        local dir = player_pos.x > pos.x and 1 or -1

        context.velocity = context.velocity or vmath.vector3()
        context.velocity.x = dir * horizontal_speed
        context.velocity.y = force
        context.facing = dir
        context.grounded = false

        return true
    end
end

-- ============================================================================
-- COMBAT ACTIONS
-- ============================================================================

--- Melee attack
-- @param damage Damage amount
-- @param range Attack range
-- @param cooldown Attack cooldown
-- @return Action function
function M.melee_attack(damage, range, cooldown)
    return function(context, dt)
        if context.attack_cooldown and context.attack_cooldown > 0 then
            return false
        end

        local attack_damage = damage or context.config.damage or 1
        local attack_range = range or context.config.attack_range or 80
        local attack_cooldown = cooldown or context.config.attack_cooldown or 1.0

        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        local distance = vmath.length(player_pos - pos)
        if distance > attack_range then return false end

        -- Deal damage to player
        local player_url = Detection.get_player_url()
        if not player_url then return false end

        pcall(msg.post, player_url, "take_damage", {
            damage = attack_damage,
            source = context.id,
            knockback = context.config.knockback_force or 200,
            direction = vmath.normalize(player_pos - pos)
        })

        context.attack_cooldown = attack_cooldown

        -- Trigger animation
        if context.url then
            msg.post(context.url, "play_animation", {name = "attack"})
        end

        return true
    end
end

--- Shoot projectile at player
-- @param config Projectile configuration
-- @return Action function
function M.shoot_at_player(config)
    config = config or {}
    return function(context, dt)
        if context.attack_cooldown and context.attack_cooldown > 0 then
            return false
        end

        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        local direction = vmath.normalize(player_pos - pos)

        -- Add prediction if configured
        if config.lead_target then
            local predicted = Detection.predict_player_position(0.3)
            if predicted then
                direction = vmath.normalize(predicted - pos)
            end
        end

        -- Spawn projectile
        local projectile_speed = config.speed or context.config.projectile_speed or 300
        local projectile_damage = config.damage or context.config.projectile_damage or 1

        factory.create(config.factory or "#projectile_factory", pos, nil, {
            velocity_x = direction.x * projectile_speed,
            velocity_y = direction.y * projectile_speed,
            damage = projectile_damage,
            owner = hash(tostring(context.id or ""))
        })

        context.attack_cooldown = config.cooldown or context.config.shoot_cooldown or 1.5

        return true
    end
end

--- Shoot spread of projectiles
-- @param count Number of projectiles
-- @param spread_angle Total spread angle in degrees
-- @param config Projectile configuration
-- @return Action function
function M.shoot_spread(count, spread_angle, config)
    count = count or 3
    spread_angle = spread_angle or 30
    config = config or {}
    return function(context, dt)
        if context.attack_cooldown and context.attack_cooldown > 0 then
            return false
        end

        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        local base_direction = vmath.normalize(player_pos - pos)
        local base_angle = math.atan2(base_direction.y, base_direction.x)

        local projectile_speed = config.speed or context.config.projectile_speed or 300
        local projectile_damage = config.damage or context.config.projectile_damage or 1

        local angle_step = math.rad(spread_angle) / (count - 1)
        local start_angle = base_angle - math.rad(spread_angle) / 2

        for i = 0, count - 1 do
            local angle = start_angle + (i * angle_step)
            local dir = vmath.vector3(math.cos(angle), math.sin(angle), 0)

            factory.create(config.factory or "#projectile_factory", pos, nil, {
                velocity_x = dir.x * projectile_speed,
                velocity_y = dir.y * projectile_speed,
                damage = projectile_damage,
                owner = hash(tostring(context.id or ""))
            })
        end

        context.attack_cooldown = config.cooldown or context.config.shoot_cooldown or 2.0

        return true
    end
end

--- Charge attack (telegraph then rush)
-- @param config Charge configuration
-- @return Action function
function M.charge_attack(config)
    config = config or {}
    return function(context, dt)
        local bb = context.blackboard

        -- Phase 1: Telegraph
        if not bb.charge_phase then
            bb.charge_phase = "telegraph"
            bb.charge_timer = 0
            bb.charge_direction = nil

            local pos = go.get_position()
            local player_pos = Detection.get_player_position()
            if player_pos then
                bb.charge_direction = vmath.normalize(player_pos - pos)
            else
                bb.charge_direction = vmath.vector3(context.facing or 1, 0, 0)
            end

            -- Visual telegraph
            if context.url then
                msg.post(context.url, "play_animation", {name = "charge_telegraph"})
            end

            return BT.STATUS.RUNNING
        end

        bb.charge_timer = bb.charge_timer + dt

        if bb.charge_phase == "telegraph" then
            local telegraph_time = config.telegraph_time or 0.6
            if bb.charge_timer >= telegraph_time then
                bb.charge_phase = "charge"
                bb.charge_timer = 0
                context.invincible = config.invincible or false
            end
            return BT.STATUS.RUNNING
        end

        if bb.charge_phase == "charge" then
            local charge_time = config.charge_time or 0.4
            local charge_speed = config.speed or 400

            context.velocity = vmath.vector3(
                bb.charge_direction.x * charge_speed,
                bb.charge_direction.y * charge_speed,
                0
            )

            if bb.charge_timer >= charge_time then
                bb.charge_phase = nil
                bb.charge_timer = nil
                bb.charge_direction = nil
                context.invincible = false
                context.velocity = vmath.vector3()
                context.attack_cooldown = config.cooldown or 2.0
                return true
            end

            return BT.STATUS.RUNNING
        end

        return false
    end
end

-- ============================================================================
-- STATE ACTIONS
-- ============================================================================

--- Set attack cooldown
-- @param duration Cooldown duration
-- @return Action function
function M.set_cooldown(duration)
    return function(context, dt)
        context.attack_cooldown = duration
        return true
    end
end

--- Play animation
-- @param name Animation name
-- @return Action function
function M.play_animation(name)
    return function(context, dt)
        if context.url then
            msg.post(context.url, "play_animation", {name = name})
        end
        return true
    end
end

--- Play sound
-- @param sound Sound name
-- @return Action function
function M.play_sound(sound)
    return function(context, dt)
        -- Play sound through audio system
        local ok, Audio = pcall(require, "mvtk.audio.audio")
        if ok and Audio then
            Audio.play_sfx(sound)
        end
        return true
    end
end

--- Set blackboard value
-- @param key Blackboard key
-- @param value Value to set
-- @return Action function
function M.set_blackboard(key, value)
    return function(context, dt)
        context.blackboard[key] = value
        return true
    end
end

--- Clear blackboard value
-- @param key Blackboard key
-- @return Action function
function M.clear_blackboard(key)
    return function(context, dt)
        context.blackboard[key] = nil
        return true
    end
end

--- Send message
-- @param url Target URL
-- @param message_id Message ID
-- @param data Message data
-- @return Action function
function M.send_message(url, message_id, data)
    return function(context, dt)
        pcall(msg.post, url, message_id, data or {})
        return true
    end
end

--- Spawn effect
-- @param factory Factory URL
-- @param offset Position offset
-- @return Action function
function M.spawn_effect(factory_url, offset)
    offset = offset or vmath.vector3()
    return function(context, dt)
        local pos = go.get_position() + offset
        factory.create(factory_url, pos)
        return true
    end
end

--- Die
-- @return Action function
function M.die()
    return function(context, dt)
        context.alive = false
        context.state = "dead"

        local EnemyManager = require "mvtk.enemies.enemy_manager"
        EnemyManager.kill_enemy(context.id, "behavior_tree")

        return true
    end
end

-- ============================================================================
-- GROUP ACTIONS
-- ============================================================================

--- Signal group to attack
-- @return Action function
function M.signal_group_attack()
    return function(context, dt)
        local GroupCoordination = require "mvtk.enemies.group_coordination"
        GroupCoordination.signal_attack(context.group_id or context.id)
        return true
    end
end

--- Wait for group signal
-- @return Action function
function M.wait_for_group_signal()
    return function(context, dt)
        local GroupCoordination = require "mvtk.enemies.group_coordination"
        if GroupCoordination.should_attack(context.id) then
            return true
        end
        return BT.STATUS.RUNNING
    end
end

--- Flank player (move to side position)
-- @param side 1 for right, -1 for left
-- @param distance Distance from player
-- @param speed Movement speed
-- @return Action function
function M.flank_player(side, distance, speed)
    side = side or 1
    distance = distance or 100
    speed = speed or 120
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        local target = vmath.vector3(
            player_pos.x + (side * distance),
            player_pos.y,
            0
        )

        local diff = target - pos
        local dist = vmath.length(diff)

        if dist < 20 then
            context.velocity = vmath.vector3()
            return true
        end

        local dir = vmath.normalize(diff)
        context.velocity = vmath.vector3(dir.x * speed, dir.y * speed, 0)
        context.facing = player_pos.x > pos.x and 1 or -1

        return BT.STATUS.RUNNING
    end
end

return M
