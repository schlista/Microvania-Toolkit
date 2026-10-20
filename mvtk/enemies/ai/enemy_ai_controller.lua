-- mvtk/enemies/ai/enemy_ai_controller.lua
-- ============================================================================
-- Enemy AI Controller - Behavior State Machine
-- ============================================================================
-- Manages enemy AI decision-making, state transitions, and behavior patterns.
-- Supports multiple behavior types (passive, defensive, aggressive, territorial, pack hunter)
-- with context-aware decision making based on player detection and situation.
--
-- State Machine Flow:
--   ┌──────┐   player      ┌───────┐   in range   ┌───────┐
--   │ IDLE │──detected────>│ ALERT │──& ready────>│ATTACK │
--   └──────┘               └───────┘              └───────┘
--      │                      │ │                      │
--      │ timeout              │ │ far away             │ cooldown
--      v                      │ v                      v
--   ┌────────┐  no player  ┌───────┐   aggressive  ┌───────┐
--   │ PATROL │<────────────│ CHASE │<──────────────│ hit   │
--   └────────┘             └───────┘               └───────┘
--      │                      │                      │
--      │ passive +            │ territorial          │ killed

local Util = require "mvtk.core.util"

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.enemies and _Dbg.enemies.ai then
        _orig_print(...)
    end
end
--      │ player seen          │ out of bounds        │
--      v                      v                      v
--   ┌─────────┐           ┌─────────┐            ┌──────┐
--   │ RETREAT │           │flee home│            │ DEAD │
--   └─────────┘           └─────────┘            └──────┘
--
-- Behavior Types:
--   PASSIVE - Never attacks, flees from player
--   DEFENSIVE - Attacks only when provoked or player is close
--   AGGRESSIVE - Chases and attacks player on sight
--   TERRITORIAL - Attacks within territory, returns to patrol area
--   PACK_HUNTER - Waits for allies, coordinates group attacks
--
-- Usage:
--   M.init(enemy_self, {behavior_type = "aggressive", detection_range = 500})
--   M.update(enemy_self, dt)  -- Call every frame
--   M.apply_damage(enemy_self, 1, source)  -- When enemy takes damage
--   M.apply_stun(enemy_self, 0.5)  -- Stun enemy for 0.5 seconds

local AttackPatterns = require "mvtk.enemies.patterns.attack_patterns"

local M = {}

-- ============================================================================
-- AI STATES AND BEHAVIOR TYPES
-- ============================================================================

-- AI state constants - possible states the enemy can be in
local AI_STATES = {
    IDLE = "idle",           -- Waiting, no action (default spawn state)
    PATROL = "patrol",       -- Moving around patrol area, not alerted
    ALERT = "alert",         -- Player detected but not attacking yet (investigation)
    CHASE = "chase",         -- Actively pursuing player
    ATTACK = "attack",       -- Executing attack pattern
    STUNNED = "stunned",     -- Temporarily disabled by stun effect
    RETREAT = "retreat",     -- Fleeing from player or returning to territory
    DEAD = "dead"            -- Enemy killed, no longer active
}

-- Behavior type constants - personality/strategy of the enemy
local BEHAVIOR_TYPES = {
    PASSIVE = "passive",           -- Never attacks, runs away when player detected
    DEFENSIVE = "defensive",       -- Attacks when attacked or when player gets too close
    AGGRESSIVE = "aggressive",     -- Attacks on sight, always chases player
    TERRITORIAL = "territorial",   -- Attacks within patrol area, returns home if pulled too far
    PACK_HUNTER = "pack_hunter"    -- Waits for allies before attacking, coordinates group tactics
}

-- ============================================================================
-- AI DATA STRUCTURE
-- ============================================================================

-- Create AI data structure with default values
-- Returns: Table containing all AI state, decision-making, and behavior data
local function create_ai_data()
    return {
        -- Core state tracking
        current_state = AI_STATES.IDLE,          -- Current AI state
        previous_state = AI_STATES.IDLE,         -- Last state (for transitions)
        state_timer = 0,                         -- Time spent in current state (seconds)
        behavior_type = BEHAVIOR_TYPES.DEFENSIVE, -- AI personality/strategy

        -- Decision making timing
        decision_timer = 0,                      -- Time since last decision
        decision_interval = 0.5,                 -- How often to reevaluate (seconds)

        -- Detection and targeting
        player_detected = false,                 -- Is player currently detected?
        target_position = nil,                   -- Current target position (vector3)
        target_distance = 0,                     -- Distance to target (pixels)
        last_known_player_pos = nil,             -- Last place player was seen
        detection_range = 400,                   -- How far enemy can see (pixels)
        attack_range = 150,                      -- Range to initiate attack (pixels)
        give_up_range = 800,                     -- Distance to abandon chase (pixels)

        -- Movement and positioning
        start_position = vmath.vector3(),        -- Spawn position for patrol/return
        patrol_radius = 200,                     -- How far to patrol from start (pixels)
        move_speed = 100,                        -- Normal patrol speed (pixels/sec)
        chase_speed = 150,                       -- Speed when chasing player (pixels/sec)
        retreat_speed = 120,                     -- Speed when fleeing (pixels/sec)

        -- Combat stats
        health = 3,                              -- Current health
        max_health = 3,                          -- Maximum health
        attack_damage = 1,                       -- Damage dealt per attack
        attack_cooldown = 0,                     -- Time until can attack again (seconds)
        attack_patterns = {},                    -- Available attack patterns (functions)
        current_pattern = nil,                   -- Active attack pattern instance
        pattern_timer = 0,                       -- Time in current pattern (seconds)

        -- Status effects
        stunned = false,                         -- Is enemy currently stunned?
        stun_timer = 0,                          -- Remaining stun duration (seconds)
        fear_timer = 0,                          -- Remaining fear duration (seconds)

        -- Group behavior (for pack hunters)
        group_id = nil,                          -- ID of group this enemy belongs to
        allies = {},                             -- List of nearby allied enemies

        -- Debug
        debug_enabled = false                    -- Print debug logs?
    }
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

-- Initialize AI system for an enemy
-- enemy_self: Enemy script instance (self from enemy script)
-- config: Optional table of AI configuration values to override defaults
--         Can set any field from create_ai_data() (e.g., detection_range, behavior_type)
--
-- Example:
--   M.init(self, {behavior_type = "aggressive", detection_range = 500, health = 5})
function M.init(enemy_self, config)
    -- Create AI data structure with defaults
    enemy_self.ai_data = create_ai_data()
    local ai = enemy_self.ai_data

    -- Apply configuration overrides if provided
    if config then
        for key, value in pairs(config) do
            if ai[key] ~= nil then  -- Only set fields that exist in default structure
                ai[key] = value
            end
        end
    end

    -- Remember spawn position for patrol and territorial behavior
    ai.start_position = go.get_position()

    -- Initialize attack patterns based on behavior type
    M.setup_attack_patterns(enemy_self)

    print(string.format("[ENEMY_AI] Initialized %s AI for enemy at (%.1f, %.1f)",
        ai.behavior_type, ai.start_position.x, ai.start_position.y))
end

-- Setup attack patterns based on behavior type
-- enemy_self: Enemy script instance
--
-- Assigns appropriate attack patterns for each behavior type:
-- - PASSIVE: No attacks
-- - DEFENSIVE: Basic stationary attacks
-- - AGGRESSIVE: Chase and melee-focused attacks
-- - TERRITORIAL: Area control and ranged attacks
-- - PACK_HUNTER: Coordinated burst attacks
function M.setup_attack_patterns(enemy_self)
    local ai = enemy_self.ai_data

    -- Assign attack patterns based on enemy's behavior personality
    if ai.behavior_type == BEHAVIOR_TYPES.PASSIVE then
        ai.attack_patterns = {}  -- Passive enemies never attack

    elseif ai.behavior_type == BEHAVIOR_TYPES.DEFENSIVE then
        -- Defensive: Wait and shoot when threatened
        ai.attack_patterns = {
            AttackPatterns[hash("idle")],
            AttackPatterns[hash("shoot_straight")]
        }

    elseif ai.behavior_type == BEHAVIOR_TYPES.AGGRESSIVE then
        -- Aggressive: Chase down and attack player
        ai.attack_patterns = {
            AttackPatterns[hash("chase_player")],
            AttackPatterns[hash("shoot_straight")],
            AttackPatterns[hash("dash_attack")]
        }

    elseif ai.behavior_type == BEHAVIOR_TYPES.TERRITORIAL then
        -- Territorial: Guard area with patrols and ranged attacks
        ai.attack_patterns = {
            AttackPatterns[hash("patrol_horizontal")],
            AttackPatterns[hash("shoot_spread")],
            AttackPatterns[hash("charge_shoot")]
        }

    elseif ai.behavior_type == BEHAVIOR_TYPES.PACK_HUNTER then
        -- Pack Hunter: Coordinated attacks with allies
        ai.attack_patterns = {
            AttackPatterns[hash("chase_player")],
            AttackPatterns[hash("shoot_burst")],
            AttackPatterns[hash("teleport_attack")]
        }
    end

    -- Initialize with first pattern if any exist
    if #ai.attack_patterns > 0 then
        ai.current_pattern = ai.attack_patterns[1]()
    end
end

-- ============================================================================
-- MAIN UPDATE LOOP
-- ============================================================================

-- Main AI update function - call every frame from enemy script
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
--
-- This orchestrates the AI system by:
-- 1. Updating timers (attack cooldown, stun duration, etc.)
-- 2. Detecting and tracking player position
-- 3. Making decisions periodically (every 0.5s by default)
-- 4. Updating current state behavior (movement, attacks, etc.)
-- 5. Managing attack pattern transitions
function M.update(enemy_self, dt)
    local ai = enemy_self.ai_data

    -- Skip update if AI not initialized or enemy is dead
    if not ai or ai.current_state == AI_STATES.DEAD then
        return
    end

    -- Update all timers (state, attack cooldown, stun, etc.)
    M.update_timers(ai, dt)

    -- Update player detection and targeting
    M.update_detection(enemy_self, dt)

    -- Make decisions at regular intervals (not every frame for performance)
    ai.decision_timer = ai.decision_timer + dt
    if ai.decision_timer >= ai.decision_interval then
        M.make_decision(enemy_self)
        ai.decision_timer = 0
    end

    -- Execute current state behavior (movement, attacks, etc.)
    M.update_state(enemy_self, dt)

    -- Update attack patterns and handle pattern switching
    M.update_attack_patterns(enemy_self, dt)
end

-- ============================================================================
-- TIMER MANAGEMENT
-- ============================================================================

-- Update all AI timers
-- ai: AI data structure
-- dt: Delta time in seconds
--
-- Manages countdown timers for attack cooldowns, status effects, etc.
function M.update_timers(ai, dt)
    -- Track time in current state
    ai.state_timer = ai.state_timer + dt

    -- Count down attack cooldown
    if ai.attack_cooldown > 0 then
        ai.attack_cooldown = ai.attack_cooldown - dt
    end

    -- Count down stun duration
    if ai.stun_timer > 0 then
        ai.stun_timer = ai.stun_timer - dt
        if ai.stun_timer <= 0 then
            ai.stunned = false  -- Stun expired, return to normal
            print("[ENEMY_AI] Stun effect ended")
        end
    end

    -- Count down fear duration (for future fear mechanics)
    if ai.fear_timer > 0 then
        ai.fear_timer = ai.fear_timer - dt
    end
end

-- ============================================================================
-- DETECTION AND TARGETING
-- ============================================================================

-- Update player detection and tracking
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
--
-- Detects player within detection_range and tracks last known position.
-- Gives up chase if player moves beyond give_up_range.
-- Remembers last known position for 5 seconds after losing sight.
function M.update_detection(enemy_self, dt)
    local ai = enemy_self.ai_data
    local enemy_pos = go.get_position()

    -- Get player position safely
    local C = require "mvtk.core.constants"
    local player_pos = nil

    if C and C.URL and C.URL.PLAYER then
        local success, pos = pcall(go.get_position, C.URL.PLAYER)
        if success then
            player_pos = pos
        end
    end

    -- Player not found or doesn't exist
    if not player_pos then
        ai.player_detected = false
        ai.target_position = nil
        ai.target_distance = 0
        return
    end

    -- Calculate distance to player
    local distance = vmath.length(player_pos - enemy_pos)
    ai.target_distance = distance

    -- Check if player is within detection range
    if distance <= ai.detection_range then
        ai.player_detected = true
        ai.target_position = player_pos
        ai.last_known_player_pos = vmath.vector3(player_pos)  -- Remember this position

        if ai.debug_enabled then
            print(string.format("[ENEMY_AI] Player detected at distance %.1f", distance))
        end

    elseif distance > ai.give_up_range then
        -- Player is too far away, abandon chase
        ai.player_detected = false
        ai.target_position = nil

        if ai.debug_enabled then
            print("[ENEMY_AI] Player lost - too far away")
        end
    end
    -- else: Player is between detection_range and give_up_range - maintain current detection state

    -- Use last known position if player was detected recently but now out of range
    if not ai.player_detected and ai.last_known_player_pos then
        local time_since_detection = ai.state_timer
        if time_since_detection < 5.0 then  -- Remember for 5 seconds
            ai.target_position = ai.last_known_player_pos
        else
            ai.last_known_player_pos = nil  -- Forget position after 5 seconds
        end
    end
end

-- ============================================================================
-- DECISION MAKING
-- ============================================================================

-- Main decision-making function - evaluates situation and chooses state
-- enemy_self: Enemy script instance
--
-- Called periodically (default every 0.5s) to reevaluate situation.
-- Checks status effects first, then delegates to behavior-specific logic.
function M.make_decision(enemy_self)
    local ai = enemy_self.ai_data

    -- Priority 1: Handle status effects (override all behavior)
    if ai.stunned then
        M.change_state(ai, AI_STATES.STUNNED)
        return
    end

    -- Priority 2: Handle death
    if ai.health <= 0 then
        M.change_state(ai, AI_STATES.DEAD)
        return
    end

    -- Priority 3: Behavior-specific decision tree
    -- Each behavior type has unique logic for reacting to situations
    if ai.behavior_type == BEHAVIOR_TYPES.PASSIVE then
        M.make_passive_decision(enemy_self)
    elseif ai.behavior_type == BEHAVIOR_TYPES.DEFENSIVE then
        M.make_defensive_decision(enemy_self)
    elseif ai.behavior_type == BEHAVIOR_TYPES.AGGRESSIVE then
        M.make_aggressive_decision(enemy_self)
    elseif ai.behavior_type == BEHAVIOR_TYPES.TERRITORIAL then
        M.make_territorial_decision(enemy_self)
    elseif ai.behavior_type == BEHAVIOR_TYPES.PACK_HUNTER then
        M.make_pack_hunter_decision(enemy_self)
    end
end

-- PASSIVE behavior: Never fights, always flees
-- enemy_self: Enemy script instance
--
-- Decision logic:
-- - If player detected → RETREAT (run away)
-- - If no player → PATROL (wander peacefully)
function M.make_passive_decision(enemy_self)
    local ai = enemy_self.ai_data

    if ai.player_detected then
        M.change_state(ai, AI_STATES.RETREAT)  -- Run away from player
    else
        M.change_state(ai, AI_STATES.PATROL)  -- Wander around when safe
    end
end

-- DEFENSIVE behavior: Guards area, attacks when threatened
-- enemy_self: Enemy script instance
--
-- Decision logic:
-- - If player detected AND in attack range AND ready → ATTACK
-- - If player detected BUT out of attack range → ALERT (watch player)
-- - If no player → PATROL (return to guard duty)
function M.make_defensive_decision(enemy_self)
    local ai = enemy_self.ai_data

    if ai.player_detected then
        if ai.target_distance <= ai.attack_range and ai.attack_cooldown <= 0 then
            M.change_state(ai, AI_STATES.ATTACK)  -- Player too close, defend ourselves
        elseif ai.target_distance <= ai.detection_range then
            M.change_state(ai, AI_STATES.ALERT)  -- Player detected, stay alert but don't chase
        end
    else
        M.change_state(ai, AI_STATES.PATROL)  -- Resume patrol when no threat
    end
end

-- AGGRESSIVE behavior: Actively hunts player
-- enemy_self: Enemy script instance
--
-- Decision logic:
-- - If player detected AND in attack range AND ready → ATTACK
-- - If player detected BUT out of attack range → CHASE (pursue aggressively)
-- - If no player → PATROL (search for player)
function M.make_aggressive_decision(enemy_self)
    local ai = enemy_self.ai_data

    if ai.player_detected then
        if ai.target_distance <= ai.attack_range and ai.attack_cooldown <= 0 then
            M.change_state(ai, AI_STATES.ATTACK)  -- Close enough to strike
        else
            M.change_state(ai, AI_STATES.CHASE)  -- Chase down the player
        end
    else
        M.change_state(ai, AI_STATES.PATROL)  -- Search for player
    end
end

-- TERRITORIAL behavior: Defends home area, won't leave territory
-- enemy_self: Enemy script instance
--
-- Decision logic:
-- - If player detected AND inside territory AND in attack range AND ready → ATTACK
-- - If player detected AND inside territory BUT out of attack range → CHASE (within bounds)
-- - If pulled too far from home → RETREAT (return to territory)
-- - Otherwise → PATROL (guard the area)
function M.make_territorial_decision(enemy_self)
    local ai = enemy_self.ai_data
    local enemy_pos = go.get_position()
    local distance_from_home = vmath.length(enemy_pos - ai.start_position)

    if ai.player_detected and distance_from_home <= ai.patrol_radius then
        -- Player in our territory, defend it
        if ai.target_distance <= ai.attack_range and ai.attack_cooldown <= 0 then
            M.change_state(ai, AI_STATES.ATTACK)  -- Attack intruder
        else
            M.change_state(ai, AI_STATES.CHASE)  -- Chase within territory
        end
    elseif distance_from_home > ai.patrol_radius then
        -- We've been pulled too far from home, return
        M.change_state(ai, AI_STATES.RETREAT)
    else
        M.change_state(ai, AI_STATES.PATROL)  -- Guard our territory
    end
end

-- PACK_HUNTER behavior: Coordinates with allies, won't attack alone
-- enemy_self: Enemy script instance
--
-- Decision logic:
-- - If player detected AND has allies AND in attack range AND ready → ATTACK (coordinated)
-- - If player detected AND has allies BUT out of range → CHASE (with pack)
-- - If player detected BUT no allies → ALERT (wait for backup, don't engage alone)
-- - If no player → PATROL (search as a pack)
function M.make_pack_hunter_decision(enemy_self)
    local ai = enemy_self.ai_data

    -- Check for nearby allies (pack hunters need backup)
    local ally_count = M.count_nearby_allies(enemy_self)

    if ai.player_detected then
        if ally_count >= 1 then  -- Have backup, can attack
            if ai.target_distance <= ai.attack_range and ai.attack_cooldown <= 0 then
                M.change_state(ai, AI_STATES.ATTACK)  -- Coordinated attack with allies
            else
                M.change_state(ai, AI_STATES.CHASE)  -- Chase together as a pack
            end
        else
            -- Alone and outnumbered, wait for allies instead of attacking
            M.change_state(ai, AI_STATES.ALERT)
        end
    else
        M.change_state(ai, AI_STATES.PATROL)  -- Search for player with pack
    end
end

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

-- Change AI state with proper cleanup and initialization
-- ai: AI data structure
-- new_state: New state to transition to (one of AI_STATES constants)
--
-- Handles state transition bookkeeping:
-- - Saves previous state for reference
-- - Resets state timer
-- - Calls state entry actions (on_state_enter)
function M.change_state(ai, new_state)
    -- Skip if already in this state (no redundant transitions)
    if ai.current_state == new_state then
        return
    end

    ai.previous_state = ai.current_state
    ai.current_state = new_state
    ai.state_timer = 0  -- Reset timer for new state

    if ai.debug_enabled then
        print(string.format("[ENEMY_AI] State change: %s -> %s", ai.previous_state, new_state))
    end

    -- Perform state entry actions (initialization for new state)
    M.on_state_enter(ai, new_state)
end

-- State entry actions - called when entering a new state
-- ai: AI data structure
-- state: State being entered
--
-- Performs initialization and cleanup specific to each state.
function M.on_state_enter(ai, state)
    if state == AI_STATES.ATTACK then
        -- Start attack cooldown when beginning attack
        ai.attack_cooldown = 1.0

    elseif state == AI_STATES.STUNNED then
        -- Stop attack pattern while stunned
        ai.current_pattern = nil

    elseif state == AI_STATES.DEAD then
        -- Clear all state when dying
        ai.current_pattern = nil
        ai.player_detected = false
    end
end

-- ============================================================================
-- STATE UPDATES - Behavior for each state
-- ============================================================================

-- Main state update dispatcher - routes to specific state handler
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
function M.update_state(enemy_self, dt)
    local ai = enemy_self.ai_data

    -- Execute behavior for current state
    if ai.current_state == AI_STATES.IDLE then
        M.update_idle_state(enemy_self, dt)

    elseif ai.current_state == AI_STATES.PATROL then
        M.update_patrol_state(enemy_self, dt)

    elseif ai.current_state == AI_STATES.ALERT then
        M.update_alert_state(enemy_self, dt)

    elseif ai.current_state == AI_STATES.CHASE then
        M.update_chase_state(enemy_self, dt)

    elseif ai.current_state == AI_STATES.ATTACK then
        M.update_attack_state(enemy_self, dt)

    elseif ai.current_state == AI_STATES.STUNNED then
        M.update_stunned_state(enemy_self, dt)

    elseif ai.current_state == AI_STATES.RETREAT then
        M.update_retreat_state(enemy_self, dt)
    end
end

-- IDLE state: Do nothing, wait for stimulus
-- enemy_self: Enemy script instance
-- dt: Delta time (unused but kept for signature consistency)
function M.update_idle_state(enemy_self, dt)
    -- Intentionally empty - idle enemies don't move or act
end

-- PATROL state: Wander around using patrol pattern
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
function M.update_patrol_state(enemy_self, dt)
    local ai = enemy_self.ai_data

    -- Execute patrol pattern if one is assigned
    if ai.current_pattern and ai.current_pattern.update then
        ai.current_pattern.update(enemy_self, dt)
    end
end

-- ALERT state: Investigating, moving cautiously toward last known player position
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
function M.update_alert_state(enemy_self, dt)
    local ai = enemy_self.ai_data

    -- Move slowly toward last known player position (cautious investigation)
    if ai.target_position then
        local enemy_pos = go.get_position()
        local direction = vmath.normalize(ai.target_position - enemy_pos)

        -- Move at half normal speed (alert and cautious)
        local move_speed = ai.move_speed * 0.5
        enemy_self.vel = enemy_self.vel or vmath.vector3()
        enemy_self.vel.x = direction.x * move_speed
        enemy_self.vel.y = direction.y * move_speed
    end
end

-- CHASE state: Actively pursuing player at high speed
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
function M.update_chase_state(enemy_self, dt)
    local ai = enemy_self.ai_data

    if ai.target_position then
        local enemy_pos = go.get_position()
        local direction = vmath.normalize(ai.target_position - enemy_pos)

        -- Move at chase speed (faster than patrol/alert)
        enemy_self.vel = enemy_self.vel or vmath.vector3()
        enemy_self.vel.x = direction.x * ai.chase_speed
        enemy_self.vel.y = direction.y * ai.chase_speed
    end
end

-- ATTACK state: Executing attack pattern, standing still
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
function M.update_attack_state(enemy_self, dt)
    local ai = enemy_self.ai_data

    -- Execute attack pattern
    if ai.current_pattern and ai.current_pattern.update then
        ai.current_pattern.update(enemy_self, dt)
    end

    -- Stop movement during attack (plant feet to attack)
    enemy_self.vel = enemy_self.vel or vmath.vector3()
    enemy_self.vel.x = 0
    enemy_self.vel.y = 0
end

-- STUNNED state: Disabled by stun effect, cannot move or act
-- enemy_self: Enemy script instance
-- dt: Delta time (unused but kept for signature consistency)
function M.update_stunned_state(enemy_self, dt)
    -- Stop all movement while stunned
    enemy_self.vel = enemy_self.vel or vmath.vector3()
    enemy_self.vel.x = 0
    enemy_self.vel.y = 0
end

-- RETREAT state: Fleeing from player or returning to territory
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
function M.update_retreat_state(enemy_self, dt)
    local ai = enemy_self.ai_data
    local enemy_pos = go.get_position()

    local retreat_target = nil

    -- Determine retreat destination based on behavior type
    if ai.behavior_type == BEHAVIOR_TYPES.PASSIVE and ai.target_position then
        -- Passive enemies flee away from player (opposite direction)
        local direction = vmath.normalize(enemy_pos - ai.target_position)
        retreat_target = enemy_pos + direction * 200  -- Run 200 pixels away

    elseif ai.behavior_type == BEHAVIOR_TYPES.TERRITORIAL then
        -- Territorial enemies return to their spawn point
        retreat_target = ai.start_position
    end

    -- Move toward retreat target
    if retreat_target then
        local direction = vmath.normalize(retreat_target - enemy_pos)
        enemy_self.vel = enemy_self.vel or vmath.vector3()
        enemy_self.vel.x = direction.x * ai.retreat_speed
        enemy_self.vel.y = direction.y * ai.retreat_speed
    end
end

-- ============================================================================
-- ATTACK PATTERN MANAGEMENT
-- ============================================================================

-- Update and manage attack pattern switching
-- enemy_self: Enemy script instance
-- dt: Delta time in seconds
--
-- Switches attack patterns every 3 seconds for variety (if multiple patterns available)
function M.update_attack_patterns(enemy_self, dt)
    local ai = enemy_self.ai_data

    ai.pattern_timer = ai.pattern_timer + dt

    -- Switch patterns periodically for variety (only if multiple patterns exist)
    if ai.pattern_timer >= 3.0 and #ai.attack_patterns > 1 then
        local new_pattern_index = math.random(1, #ai.attack_patterns)
        ai.current_pattern = ai.attack_patterns[new_pattern_index]()
        ai.pattern_timer = 0

        if ai.debug_enabled then
            print("[ENEMY_AI] Switched to new attack pattern")
        end
    end
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- Count nearby allied enemies (for pack hunter coordination)
-- enemy_self: Enemy script instance
-- Returns: Number of nearby allies
--
-- Queries the enemy management system to find actual nearby enemies
-- with the same group_id within detection range.
function M.count_nearby_allies(enemy_self)
    if not enemy_self.id then return 0 end
    
    local EnemyManager = require "mvtk.enemies.enemy_manager"
    local enemy = EnemyManager.get_enemy(enemy_self.id)
    if not enemy or not enemy.alive or not enemy.position then return 0 end
    
    -- Get ally detection range from config (default 200 pixels)
    local range = enemy.config.ally_detection_range or 200
    local group_id = enemy.config.group_id
    
    -- Get all enemies within range
    local nearby = EnemyManager.get_enemies_in_range(enemy.position, range)
    
    -- Count allies (exclude self, only count same group if group_id is set)
    local count = 0
    for _, entry in ipairs(nearby) do
        local other = entry.enemy
        if other.id ~= enemy.id and other.alive then
            -- If group_id is set, only count same group; otherwise count all nearby enemies as allies
            if not group_id or other.config.group_id == group_id then
                count = count + 1
            end
        end
    end
    
    return count
end

-- ============================================================================
-- COMBAT INTERFACE
-- ============================================================================

-- Apply damage to enemy
-- enemy_self: Enemy script instance
-- amount: Damage amount (number)
-- source: Source of damage (optional, for future use)
--
-- Reduces health and triggers death or reaction based on behavior type.
-- Defensive enemies wake up when attacked.
-- Passive enemies flee when attacked.
function M.apply_damage(enemy_self, amount, source)
    local ai = enemy_self.ai_data

    -- Ignore damage if not initialized or already dead
    if not ai or ai.current_state == AI_STATES.DEAD then
        return
    end

    ai.health = ai.health - amount

    print(string.format("[ENEMY_AI] Enemy took %d damage - Health: %d/%d",
        amount, ai.health, ai.max_health))

    if ai.health <= 0 then
        -- Enemy killed
        M.change_state(ai, AI_STATES.DEAD)
    else
        -- React to damage based on behavior type
        if ai.behavior_type == BEHAVIOR_TYPES.PASSIVE then
            M.change_state(ai, AI_STATES.RETREAT)  -- Passive enemies flee when hit

        elseif ai.behavior_type == BEHAVIOR_TYPES.DEFENSIVE and not ai.player_detected then
            ai.player_detected = true  -- Wake up defensive enemies when attacked
            M.change_state(ai, AI_STATES.ALERT)
        end
    end
end

-- Apply stun effect to enemy
-- enemy_self: Enemy script instance
-- duration: Stun duration in seconds
--
-- Stuns enemy, preventing movement and actions for specified duration.
function M.apply_stun(enemy_self, duration)
    local ai = enemy_self.ai_data

    if ai and ai.current_state ~= AI_STATES.DEAD then
        ai.stunned = true
        ai.stun_timer = duration
        M.change_state(ai, AI_STATES.STUNNED)

        print(string.format("[ENEMY_AI] Enemy stunned for %.1f seconds", duration))
    end
end

-- ============================================================================
-- DEBUG AND QUERY
-- ============================================================================

-- Get current AI state snapshot for debugging/UI
-- enemy_self: Enemy script instance
-- Returns: Table with current AI state info, or nil if not initialized
function M.get_ai_state(enemy_self)
    local ai = enemy_self.ai_data

    if not ai then
        return nil
    end

    return {
        state = ai.current_state,
        behavior_type = ai.behavior_type,
        health = ai.health,
        max_health = ai.max_health,
        player_detected = ai.player_detected,
        target_distance = ai.target_distance,
        stunned = ai.stunned,
        attack_cooldown = ai.attack_cooldown
    }
end

-- Enable/disable debug logging for this enemy
-- enemy_self: Enemy script instance
-- enabled: true to enable debug logs, false to disable
function M.set_debug(enemy_self, enabled)
    local ai = enemy_self.ai_data

    if ai then
        ai.debug_enabled = enabled
    end
end

return M
