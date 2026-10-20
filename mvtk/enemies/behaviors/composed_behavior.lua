-- mvtk/enemies/behaviors/composed_behavior.lua
-- ============================================================================
-- Composed Behavior System - Mix and Match Behaviors
-- ============================================================================
-- Allows enemies to combine multiple behavior modules into one cohesive AI.
-- For example: patrol + ranged_attack + retreat_when_low
--
-- Usage:
--   local ComposedBehavior = require "mvtk.enemies.behaviors.composed_behavior"
--
--   local behavior = ComposedBehavior.create({
--       "ground_patrol",
--       "ranged_attack",
--       "retreat_when_low"
--   })
--
--   -- In enemy script:
--   behavior:init(self, config)
--   behavior:update(self, dt)

local M = {}

local BT = require "mvtk.enemies.ai.behavior_tree"
local Conditions = require "mvtk.enemies.ai.bt_conditions"
local Actions = require "mvtk.enemies.ai.bt_actions"

-- ============================================================================
-- BEHAVIOR MODULES
-- ============================================================================

-- Each module returns a behavior tree node that can be composed
local behavior_modules = {}

--- Ground Patrol: Walk back and forth
behavior_modules.ground_patrol = function(config)
    config = config or {}
    local patrol_speed = config.patrol_speed or config.speed or 50
    local patrol_distance = config.patrol_distance or 200

    return BT.sequence({
        BT.inverter(BT.condition(Conditions.player_in_range(config.detection_range or 150))),
        BT.action(Actions.patrol_horizontal(patrol_speed, patrol_distance)),
    })
end

--- Chase Player: Move toward player when detected
behavior_modules.chase_player = function(config)
    config = config or {}
    local chase_speed = config.chase_speed or 100
    local detection_range = config.detection_range or 200

    return BT.sequence({
        BT.condition(Conditions.player_in_range(detection_range)),
        BT.condition(Conditions.player_visible()),
        BT.action(Actions.face_player()),
        BT.action(Actions.move_toward_player(chase_speed)),
    })
end

--- Melee Attack: Attack when in range
behavior_modules.melee_attack = function(config)
    config = config or {}
    local attack_range = config.attack_range or 80
    local damage = config.damage or 1
    local cooldown = config.attack_cooldown or 1.0

    return BT.sequence({
        BT.condition(Conditions.player_in_attack_range(attack_range)),
        BT.condition(Conditions.can_attack()),
        BT.action(Actions.stop()),
        BT.action(Actions.face_player()),
        BT.action(Actions.melee_attack(damage, attack_range, cooldown)),
    })
end

--- Ranged Attack: Shoot at player from distance
behavior_modules.ranged_attack = function(config)
    config = config or {}
    local attack_range = config.attack_range or 200
    local detection_range = config.detection_range or 250

    return BT.sequence({
        BT.condition(Conditions.player_in_range(detection_range)),
        BT.condition(Conditions.can_attack()),
        BT.condition(Conditions.player_visible()),
        BT.action(Actions.stop()),
        BT.action(Actions.face_player()),
        BT.action(Actions.shoot_at_player({
            speed = config.projectile_speed or 250,
            damage = config.projectile_damage or 1,
            cooldown = config.shoot_cooldown or 1.5,
            lead_target = config.lead_target or false,
        })),
    })
end

--- Spread Attack: Shoot spread of projectiles
behavior_modules.spread_attack = function(config)
    config = config or {}

    return BT.sequence({
        BT.condition(Conditions.player_in_range(config.detection_range or 250)),
        BT.condition(Conditions.can_attack()),
        BT.condition(Conditions.player_visible()),
        BT.action(Actions.stop()),
        BT.action(Actions.face_player()),
        BT.action(Actions.shoot_spread(
            config.projectile_count or 3,
            config.spread_angle or 30,
            {
                speed = config.projectile_speed or 250,
                damage = config.projectile_damage or 1,
                cooldown = config.shoot_cooldown or 2.0,
            }
        )),
    })
end

--- Charge Attack: Telegraph then rush at player
behavior_modules.charge_attack = function(config)
    config = config or {}

    return BT.sequence({
        BT.condition(Conditions.player_in_range(config.charge_trigger_range or 200)),
        BT.condition(Conditions.player_on_same_level(50)),
        BT.condition(Conditions.can_attack()),
        BT.action(Actions.charge_attack({
            telegraph_time = config.telegraph_time or 0.6,
            charge_time = config.charge_time or 0.4,
            speed = config.charge_speed or 400,
            cooldown = config.charge_cooldown or 2.5,
            invincible = config.charge_invincible or false,
        })),
    })
end

--- Retreat When Low: Back away when health is low
behavior_modules.retreat_when_low = function(config)
    config = config or {}
    local health_threshold = config.retreat_threshold or 0.3
    local retreat_speed = config.retreat_speed or 80

    return BT.sequence({
        BT.condition(Conditions.health_below(health_threshold)),
        BT.condition(Conditions.player_in_range(200)),
        BT.action(Actions.move_away_from_player(retreat_speed)),
    })
end

--- Return Home: Go back to spawn when player is gone
behavior_modules.return_home = function(config)
    config = config or {}
    local speed = config.speed or 60

    return BT.sequence({
        BT.inverter(BT.condition(Conditions.player_in_range(config.detection_range or 200))),
        BT.inverter(BT.condition(Conditions.near_home(50))),
        BT.action(Actions.move_toward_home(speed, 30)),
    })
end

--- Flying Hover: Float and bob in the air
behavior_modules.flying_hover = function(config)
    config = config or {}

    return BT.action(function(context, dt)
        -- Apply hover bobbing
        context.blackboard.hover_time = (context.blackboard.hover_time or 0) + dt
        local bob = math.sin(context.blackboard.hover_time * 3) * 10

        context.velocity = context.velocity or vmath.vector3()
        context.velocity.y = bob

        return true
    end)
end

--- Jump Attack: Jump toward player
behavior_modules.jump_attack = function(config)
    config = config or {}
    local jump_range = config.jump_range or 150
    local jump_force = config.jump_force or 500

    return BT.sequence({
        BT.condition(Conditions.player_in_range(jump_range)),
        BT.condition(Conditions.is_grounded()),
        BT.condition(Conditions.can_attack()),
        BT.action(Actions.jump_toward_player(jump_force, config.horizontal_speed or 150)),
        BT.action(Actions.set_cooldown(config.jump_cooldown or 2.0)),
    })
end

--- Dash Attack: Quick dash toward player
behavior_modules.dash_attack = function(config)
    config = config or {}

    return BT.sequence({
        BT.condition(Conditions.player_in_range(config.dash_range or 150)),
        BT.condition(Conditions.can_attack()),
        BT.action(Actions.dash_toward_player(
            config.dash_speed or 400,
            config.dash_duration or 0.3
        )),
        BT.action(Actions.set_cooldown(config.dash_cooldown or 1.5)),
    })
end

--- Idle: Do nothing
behavior_modules.idle = function(config)
    return BT.action(Actions.stop())
end

--- Face Player Always: Keep facing the player
behavior_modules.face_player_always = function(config)
    return BT.succeeder(BT.action(Actions.face_player()))
end

--- Summon Minions: Spawn other enemies
behavior_modules.summon_minions = function(config)
    config = config or {}

    return BT.sequence({
        BT.condition(Conditions.player_in_range(config.summon_trigger_range or 300)),
        BT.condition(Conditions.can_attack()),
        BT.action(function(context, dt)
            local EnemyManager = require "mvtk.enemies.enemy_manager"
            local pos = go.get_position()

            local summon_type = config.summon_type or "swarm"
            local summon_count = config.summon_count or 2

            for i = 1, summon_count do
                local offset = vmath.vector3(
                    math.random(-100, 100),
                    math.random(-50, 50),
                    0
                )
                EnemyManager.spawn_enemy(summon_type, pos + offset, {
                    summoner = context.id,
                    room_id = context.room_id,
                })
            end

            context.attack_cooldown = config.summon_cooldown or 5.0
            return true
        end),
    })
end

--- Heal Allies: Heal nearby friendly enemies
behavior_modules.heal_allies = function(config)
    config = config or {}

    return BT.sequence({
        BT.condition(Conditions.can_attack()),
        BT.action(function(context, dt)
            local EnemyManager = require "mvtk.enemies.enemy_manager"
            local pos = go.get_position()
            local heal_range = config.heal_range or 150
            local heal_amount = config.heal_amount or 1

            local nearby = EnemyManager.get_enemies_in_range(pos, heal_range)
            local healed = false

            for _, entry in ipairs(nearby) do
                local enemy = entry.enemy
                if enemy.id ~= context.id and enemy.alive then
                    if enemy.health < enemy.max_health then
                        EnemyManager.heal_enemy(enemy.id, heal_amount)
                        healed = true
                    end
                end
            end

            if healed then
                context.attack_cooldown = config.heal_cooldown or 3.0
            end

            return healed
        end),
    })
end

--- Group Flank: Position to flank the player with allies
behavior_modules.group_flank = function(config)
    config = config or {}

    return BT.sequence({
        BT.condition(Conditions.has_allies(200, 1)),
        BT.condition(Conditions.player_in_range(300)),
        BT.action(function(context, dt)
            -- Determine flank side based on enemy position in group
            local pos = go.get_position()
            local Detection = require "mvtk.enemies.detection"
            local player_pos = Detection.get_player_position()
            if not player_pos then return false end

            -- Use enemy ID hash to determine side
            local hash_val = 0
            for i = 1, #context.id do
                hash_val = hash_val + string.byte(context.id, i)
            end

            local side = (hash_val % 2 == 0) and 1 or -1
            local flank_distance = config.flank_distance or 120

            return Actions.flank_player(side, flank_distance, config.flank_speed or 100)(context, dt)
        end),
    })
end

-- ============================================================================
-- COMPOSED BEHAVIOR CLASS
-- ============================================================================

local ComposedBehavior = {}
ComposedBehavior.__index = ComposedBehavior

function ComposedBehavior.new(behavior_ids, config)
    local self = setmetatable({}, ComposedBehavior)

    self.config = config or {}
    self.behavior_tree = nil
    self.blackboard = {}

    -- Build composed behavior tree
    self:build_tree(behavior_ids)

    return self
end

function ComposedBehavior:build_tree(behavior_ids)
    local children = {}

    for _, id in ipairs(behavior_ids) do
        local module_fn = behavior_modules[id]
        if module_fn then
            local node = module_fn(self.config)
            table.insert(children, node)
        else
            print("[COMPOSED_BEHAVIOR] Unknown behavior module:", id)
        end
    end

    -- Create selector that tries each behavior in priority order
    if #children > 0 then
        self.behavior_tree = BT.tree(BT.selector(children))
    end
end

function ComposedBehavior:init(enemy_self, config)
    -- Merge config
    if config then
        for k, v in pairs(config) do
            self.config[k] = v
        end
    end

    -- Store spawn position
    enemy_self.spawn_position = go.get_position()
    enemy_self.home_position = enemy_self.spawn_position

    -- Initialize velocity
    enemy_self.velocity = vmath.vector3()
    enemy_self.facing = 1
end

function ComposedBehavior:update(enemy_self, dt)
    if not self.behavior_tree then return end

    -- Build context for behavior tree
    local context = {
        id = enemy_self.id,
        config = self.config,
        health = enemy_self.health or enemy_self.max_health,
        max_health = enemy_self.max_health or 3,
        velocity = enemy_self.velocity or vmath.vector3(),
        facing = enemy_self.facing or 1,
        grounded = enemy_self.grounded,
        stunned = enemy_self.stunned,
        invincible = enemy_self.invincible,
        attack_cooldown = enemy_self.attack_cooldown or 0,
        home_position = enemy_self.home_position,
        spawn_position = enemy_self.spawn_position,
        room_id = enemy_self.room_id,
        url = enemy_self.url,
        blackboard = self.blackboard,
    }

    -- Run behavior tree
    self.behavior_tree:run(context, dt)

    -- Apply results back to enemy
    enemy_self.velocity = context.velocity
    enemy_self.facing = context.facing
    enemy_self.attack_cooldown = context.attack_cooldown
    enemy_self.invincible = context.invincible

    -- Update attack cooldown
    if enemy_self.attack_cooldown and enemy_self.attack_cooldown > 0 then
        enemy_self.attack_cooldown = enemy_self.attack_cooldown - dt
    end
end

function ComposedBehavior:cleanup(enemy_self)
    self.blackboard = {}
end

-- ============================================================================
-- FACTORY FUNCTIONS
-- ============================================================================

--- Create a composed behavior from behavior IDs
-- @param behavior_ids List of behavior module names
-- @param config Optional configuration
-- @return ComposedBehavior instance
function M.create(behavior_ids, config)
    return ComposedBehavior.new(behavior_ids, config)
end

--- Register a custom behavior module
-- @param id Module identifier
-- @param module_fn Function that returns a behavior tree node
function M.register_module(id, module_fn)
    behavior_modules[id] = module_fn
    print("[COMPOSED_BEHAVIOR] Registered module:", id)
end

--- Get list of available behavior modules
-- @return Table of module IDs
function M.get_available_modules()
    local ids = {}
    for id, _ in pairs(behavior_modules) do
        table.insert(ids, id)
    end
    table.sort(ids)
    return ids
end

-- ============================================================================
-- PRESET COMPOSITIONS
-- ============================================================================

--- Create preset enemy behaviors
M.presets = {
    -- Basic ground enemy
    basic_walker = function(config)
        return M.create({
            "melee_attack",
            "chase_player",
            "ground_patrol"
        }, config)
    end,

    -- Ranged enemy that keeps distance
    ranged_shooter = function(config)
        return M.create({
            "ranged_attack",
            "retreat_when_low",
            "ground_patrol"
        }, config)
    end,

    -- Aggressive charger
    aggressive_charger = function(config)
        return M.create({
            "charge_attack",
            "chase_player",
            "ground_patrol"
        }, config)
    end,

    -- Flying chaser
    flying_chaser = function(config)
        return M.create({
            "melee_attack",
            "chase_player",
            "flying_hover"
        }, config)
    end,

    -- Jumping attacker
    jumping_attacker = function(config)
        return M.create({
            "jump_attack",
            "chase_player",
            "ground_patrol"
        }, config)
    end,

    -- Summoner enemy
    summoner = function(config)
        return M.create({
            "summon_minions",
            "retreat_when_low",
            "ground_patrol"
        }, config)
    end,

    -- Healer support
    healer_support = function(config)
        return M.create({
            "heal_allies",
            "retreat_when_low",
            "ground_patrol"
        }, config)
    end,

    -- Pack hunter that flanks
    pack_hunter = function(config)
        return M.create({
            "melee_attack",
            "group_flank",
            "chase_player",
            "ground_patrol"
        }, config)
    end,

    -- Hit and run
    hit_and_run = function(config)
        return M.create({
            "dash_attack",
            "retreat_when_low",
            "chase_player",
            "ground_patrol"
        }, config)
    end,
}

return M
