-- mvtk/enemies/enemy_manager.lua
-- Central enemy system manager
-- Part of MV Toolkit - enables developers to easily populate their worlds with enemies

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })
local EnemySkins = Util.require_config("developer.config.enemy_skins_generated", { skins = {} })
if type(EnemySkins.skins) ~= "table" then
    EnemySkins = { skins = {} }
end
local Difficulty = Util.require_module("mvtk.core.difficulty")
local Time = require "mvtk.core.time"
local EnemySettings = Util.require_module("developer.config.enemy_settings")
local Templates = Util.require_module("mvtk.enemies.enemy_templates")
local C = require "mvtk.core.constants"
-- Loader split out under loaders/ so the multi-fallback enemy-types
-- resolution chain can be unit-tested without dragging the manager in.
local EnemyTypesLoader = require "mvtk.enemies.loaders.enemy_types_loader"
local EnemyTypeOverlay = require "mvtk.enemies.enemy_type_overlay"
local ConfigResolver = require "mvtk.enemies.loaders.config_resolver"
local SpawnCoordinator = require "mvtk.enemies.loaders.spawn_coordinator"

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local function print(...)  -- luacheck: ignore 121
    if Debug.enemies and Debug.enemies.spawner then
        _orig_print(...)
    end
end

local M = {}
local DEFAULT_MAX_ENEMIES_PER_ROOM = 0
if EnemySettings then
    DEFAULT_MAX_ENEMIES_PER_ROOM = tonumber(EnemySettings.max_enemies_per_room) or 0
end

-- Active enemies registry
local spawn_state = SpawnCoordinator.new_state()
local active_enemies = spawn_state.active_enemies
local enemy_types = {}
local enemy_type_overlay_cache = {}
local enemy_configs = {}

-- Forward-declare local helpers used before their definition
local spawn_drop

local enemy_log = Util.make_debug_log("[ENEMY_MGR]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.enemies)
end)

local function load_enemy_types()
    -- Delegates to the extracted loader module. The print() local in this
    -- file is debug-gated, so passing it through preserves the previous
    -- "warnings only when debug.enemies.spawner is on" behaviour.
    return EnemyTypesLoader.load(print)
end

-----------------------------------------------------------
-- Initialization
-----------------------------------------------------------

function M.init()
    enemy_log("Initializing enemy system...")

    -- Load enemy type definitions (skip if already lazy-loaded by spawn_enemy)
    if next(enemy_types) == nil then
        local types = load_enemy_types()
        if type(types) == "table" then
            -- Register all developer-defined types as templates and resolve inheritance
            if Templates then
                for type_id, def in pairs(types) do
                    Templates.register(type_id, def)
                end
                -- Resolve inheritance for any type that uses 'extends'
                local resolved_count = 0
                for type_id, def in pairs(types) do
                    if def.extends then
                        local resolved = Templates.resolve(type_id)
                        if resolved then
                            types[type_id] = resolved
                            resolved_count = resolved_count + 1
                        end
                    end
                end
                if resolved_count > 0 then
                    enemy_log(string.format("Resolved template inheritance for %d enemy types", resolved_count))
                end
            end
            enemy_types = types
            enemy_type_overlay_cache = {}
            enemy_log(string.format("Loaded %d enemy type definitions", Util.count_keys(enemy_types)))
        else
            enemy_log("WARNING: developer/config/enemy_types.lua not found or invalid")
            enemy_types = {}
            enemy_type_overlay_cache = {}
        end
    else
        enemy_log(string.format("Enemy types already loaded (%d definitions)", Util.count_keys(enemy_types)))
    end

    -- Load room enemy configurations
    if next(enemy_configs) == nil then
        enemy_configs = ConfigResolver.load_room_configs(enemy_log)
    end

    -- Preserve already-active enemies from early baked spawns (init-order race protection).
    -- stream_manager may have loaded rooms before this init() was called,
    -- so merged enemy.script instances could already be tracked.
    if next(active_enemies) == nil then
        SpawnCoordinator.reset(spawn_state)
        active_enemies = spawn_state.active_enemies
    else
        enemy_log(string.format("Preserving %d already-active enemies from early spawn", Util.count_keys(active_enemies)))
    end
end

-----------------------------------------------------------
-- Enemy Type Management
-----------------------------------------------------------

function M.get_enemy_type(type_id)
    return EnemyTypeOverlay.resolve(type_id, enemy_types, EnemySkins, {
        cache = enemy_type_overlay_cache,
        logger = function(message)
            _orig_print("[ENEMY] " .. tostring(message))
        end,
    })
end

function M.register_enemy_type(type_id, definition)
    if not type_id or type(definition) ~= "table" then
        enemy_log("ERROR: Invalid enemy type registration")
        return false
    end

    enemy_types[type_id] = definition
    enemy_type_overlay_cache[type_id] = nil
    enemy_log(string.format("Registered custom enemy type: %s", type_id))
    return true
end

function M.get_all_enemy_types()
    return enemy_types
end

-----------------------------------------------------------
-- Enemy Instance Management
-----------------------------------------------------------

function M.spawn_enemy(enemy_type_id, position, config)
    if not enemy_type_id then
        enemy_log("ERROR: No enemy type specified")
        return nil
    end

    -- Lazy-load enemy types if not yet initialized.
    -- Handles init-order race: stream_manager may create rooms (and thus
    -- baked enemy.script instances) before main.script calls EnemyManager.init().
    if next(enemy_types) == nil then
        local types = load_enemy_types()
        if type(types) == "table" then
            if Templates then
                for type_id, def in pairs(types) do
                    Templates.register(type_id, def)
                end
                for type_id, def in pairs(types) do
                    if def.extends then
                        local resolved = Templates.resolve(type_id)
                        if resolved then types[type_id] = resolved end
                    end
                end
            end
            enemy_types = types
            enemy_type_overlay_cache = {}
            enemy_log(string.format("Auto-loaded %d enemy type definitions (init-order race)", Util.count_keys(enemy_types)))
        end
    end

    local enemy_type = M.get_enemy_type(enemy_type_id)
    if not enemy_type then
        -- Try resolving as a template archetype (e.g., "tank", "glass_cannon")
        if Templates and Templates.resolve then
            enemy_type = Templates.resolve(enemy_type_id)
        end
    end
    if not enemy_type then
        enemy_log(string.format("ERROR: Unknown enemy type: %s", enemy_type_id))
        return nil
    end

    local room_id = config and config.room_id
    local limit = SpawnCoordinator.resolve_limit(config, DEFAULT_MAX_ENEMIES_PER_ROOM)
    if not SpawnCoordinator.can_spawn(spawn_state, room_id, limit) then
        enemy_log(string.format("Spawn cap reached for room %s (limit=%d)", tostring(room_id), limit))
        return nil
    end

    -- Generate unique enemy ID
    local enemy_id = SpawnCoordinator.next_enemy_id(spawn_state)

    -- Merge configuration with type defaults
    local merged_config = ConfigResolver.merge_enemy_config(enemy_type, config or {})
    merged_config.type_id = enemy_type_id
    merged_config.id = enemy_id
    merged_config.position = position
    merged_config.room_id = merged_config.room_id or room_id

    -- Apply spawn config multipliers (from wave system, Tiled overrides, etc.)
    local scaled_stats = SpawnCoordinator.apply_spawn_multipliers(merged_config)

    -- Initialize enemy state
    local enemy = SpawnCoordinator.build_enemy(enemy_id, enemy_type_id, position, merged_config, Time.gettime(), scaled_stats)

    -- Additional difficulty scaling for health (from difficulty system)
    if Difficulty and Difficulty.enemy_health_mult then
        local mult = Difficulty.enemy_health_mult() or 1.0
        enemy.max_health = math.max(1, math.floor((enemy.max_health or 1) * mult + 0.5))
        enemy.health = enemy.max_health
    end

    -- Store active enemy
    SpawnCoordinator.track(spawn_state, enemy)

    enemy_log(string.format("Spawned enemy: %s (type: %s)", enemy_id, enemy_type_id))
    return enemy_id
end

function M.register_enemy_instance(enemy_id, enemy_url)
    if active_enemies[enemy_id] then
        active_enemies[enemy_id].url = enemy_url
        enemy_log(string.format("Registered enemy instance: %s", enemy_id))
    end
end

function M.unregister_enemy_instance(enemy_id)
    local enemy = SpawnCoordinator.untrack(spawn_state, enemy_id)
    if not enemy then return end
    enemy_log(string.format("Unregistered enemy instance: %s", enemy_id))
end

-----------------------------------------------------------
-- Enemy State Management
-----------------------------------------------------------

function M.damage_enemy(enemy_id, damage, source)
    local enemy = active_enemies[enemy_id]
    if not enemy or not enemy.alive then return false end

    -- Check invincibility
    if enemy.invincible or enemy.invincible_timer > 0 then
        return false
    end

    -- Apply damage
    enemy.health = enemy.health - damage
    enemy_log(string.format("Enemy %s took %d damage (health: %d/%d)",
        enemy_id, damage, enemy.health, enemy.max_health))

    -- Notify enemy instance
    if enemy.url then
        pcall(msg.post, enemy.url, C.MSG.TAKE_DAMAGE, {
            damage = damage,
            source = source
        })
    end

    -- Check death
    if enemy.health <= 0 then
        M.kill_enemy(enemy_id, source)
        return true
    end

    -- Apply invincibility frames
    enemy.invincible_timer = enemy.config.invincibility_time or 0.5

    return true
end

function M.kill_enemy(enemy_id, source)
    local enemy = active_enemies[enemy_id]
    if not enemy or not enemy.alive then return end

    enemy.alive = false
    enemy.state = "dead"

    enemy_log(string.format("Enemy killed: %s", enemy_id))

    -- Notify enemy instance for death animation
    if enemy.url then
        pcall(msg.post, enemy.url, C.MSG.KILLED, {source = source})
    end

    -- Spawn drops
    M.spawn_enemy_drops(enemy)

    -- Global event
    pcall(msg.post, "/game_manager#game_manager", C.MSG.ENEMY_KILLED, {
        enemy_id = enemy_id,
        enemy_type = enemy.type_id
    })
end

function M.heal_enemy(enemy_id, amount)
    local enemy = active_enemies[enemy_id]
    if not enemy or not enemy.alive then return end

    enemy.health = math.min(enemy.health + amount, enemy.max_health)
end

-----------------------------------------------------------
-- Drop System
-----------------------------------------------------------

function M.spawn_enemy_drops(enemy)
    -- Check for per-instance loot table override (from Tiled properties)
    local loot_table_id = enemy.config.loot_table
    local drops = nil
    
    if loot_table_id then
        -- Load loot table from configuration
        local ok, LootTables = pcall(require, "developer.config.loot_tables")
        if ok and LootTables and LootTables[loot_table_id] then
            drops = LootTables[loot_table_id]
            enemy_log(string.format("Using custom loot table '%s' for enemy %s", loot_table_id, enemy.id))
        else
            enemy_log(string.format("WARNING: Loot table '%s' not found, using default drops", loot_table_id))
            drops = enemy.config.drops
        end
    else
        drops = enemy.config.drops
    end
    
    if not drops then return end

    for drop_id, drop_config in pairs(drops) do
        local chance = drop_config.chance or 1.0

        if math.random() <= chance then
            spawn_drop(enemy.position, drop_id, drop_config)
        end
    end
end

spawn_drop = function(position, drop_id, config)
    -- Add slight random offset
    local offset = vmath.vector3(
        math.random(-20, 20),
        math.random(10, 30),
        0
    )
    local spawn_pos = position + offset

    if drop_id == "currency" then
        local amount = math.random(config.min or 1, config.max or 5)
        if Difficulty and Difficulty.loot_mult then
            local lm = Difficulty.loot_mult() or 1.0
            amount = math.max(1, math.floor(amount * lm + 0.5))
        end
        factory.create("#currency_drop_factory", spawn_pos, nil, {amount = amount})

    elseif drop_id:find("health") then
        local heal_amount = 1
        if drop_id == "health_small" then heal_amount = 1
        elseif drop_id == "health_medium" then heal_amount = 2
        elseif drop_id == "health_large" then heal_amount = 3
        end
        factory.create("#health_drop_factory", spawn_pos, nil, {heal = heal_amount})

    elseif drop_id:find("energy") then
        local restore_amount = config.amount or 25
        factory.create("#energy_drop_factory", spawn_pos, nil, {energy = restore_amount})

    else
        -- Generic item drop
        factory.create("#item_drop_factory", spawn_pos, nil, { item_id = hash(drop_id or "") })
    end
end

-----------------------------------------------------------
-- Room Integration
-----------------------------------------------------------

function M.load_room_enemies(room_id)
    if not room_id then return {} end

    local room_enemies = ConfigResolver.get_room_config(enemy_configs, room_id)
    if not room_enemies then
        enemy_log(string.format("No enemies configured for room: %s", room_id))
        return {}
    end

    local spawned = {}
    for _, enemy_config in ipairs(room_enemies) do
        if enemy_config.type and enemy_config.position then
            local position = ConfigResolver.position_from_config(enemy_config)

            local enemy_id = M.spawn_enemy(enemy_config.type, position, enemy_config)
            if enemy_id then
                local enemy = M.get_enemy(enemy_id)
                if enemy then
                    enemy.room_id = room_id
                end
                table.insert(spawned, enemy_id)
            end
        end
    end

    enemy_log(string.format("Loaded %d enemies for room: %s", #spawned, room_id))
    return spawned
end

function M.unload_room_enemies(room_id)
    local count = 0
    for enemy_id, enemy in pairs(active_enemies) do
        if enemy.room_id == room_id then
            M.unregister_enemy_instance(enemy_id)
            count = count + 1
        end
    end
    enemy_log(string.format("Unloaded %d enemies from room: %s", count, room_id))
end

function M.clear_room_enemies(room_id)
    M.unload_room_enemies(room_id)
end

-----------------------------------------------------------
-- Query Functions
-----------------------------------------------------------

function M.get_enemy(enemy_id)
    return active_enemies[enemy_id]
end

function M.is_alive(enemy_id)
    local enemy = active_enemies[enemy_id]
    return enemy and enemy.alive or false
end

function M.get_enemy_config(enemy_id)
    local enemy = active_enemies[enemy_id]
    return enemy and enemy.config or nil
end

function M.set_enemy_position(enemy_id, position)
    local enemy = active_enemies[enemy_id]
    if not enemy or not position then
        return
    end
    enemy.position = vmath.vector3(position)
end

function M.remove_enemy(enemy_id)
    M.unregister_enemy_instance(enemy_id)
end

function M.get_all_enemies()
    return active_enemies
end

function M.get_enemies_by_type(enemy_type)
    local result = {}
    for _, enemy in pairs(active_enemies) do
        if enemy.type_id == enemy_type then
            table.insert(result, enemy)
        end
    end
    return result
end

function M.get_living_enemies()
    local result = {}
    for _, enemy in pairs(active_enemies) do
        if enemy.alive then
            table.insert(result, enemy)
        end
    end
    return result
end

function M.get_enemies_in_range(position, range)
    local result = {}
    for _, enemy in pairs(active_enemies) do
        if enemy.alive then
            local dist = vmath.length(enemy.position - position)
            if dist <= range then
                table.insert(result, {enemy = enemy, distance = dist})
            end
        end
    end

    -- Sort by distance
    table.sort(result, function(a, b) return a.distance < b.distance end)
    return result
end

function M.get_enemy_count()
    local count = 0
    for _, enemy in pairs(active_enemies) do
        if enemy.alive then
            count = count + 1
        end
    end
    return count
end

-----------------------------------------------------------
-- Update System
-----------------------------------------------------------

function M.update(dt)
    -- Update invincibility timers
    for _, enemy in pairs(active_enemies) do
        if enemy.invincible_timer > 0 then
            enemy.invincible_timer = enemy.invincible_timer - dt
            if enemy.invincible_timer <= 0 then
                enemy.invincible = false
            end
        end
    end
end

-----------------------------------------------------------
-- Debug Functions
-----------------------------------------------------------

function M.kill_all_enemies()
    local count = 0
    for enemy_id, enemy in pairs(active_enemies) do
        if enemy.alive then
            M.kill_enemy(enemy_id, "debug")
            count = count + 1
        end
    end
    enemy_log(string.format("DEBUG: Killed all enemies (%d)", count))
end

function M.damage_all_enemies(damage)
    for enemy_id, enemy in pairs(active_enemies) do
        if enemy.alive then
            M.damage_enemy(enemy_id, damage, "debug")
        end
    end
end

function M.print_enemy_status()
    enemy_log("=== Enemy Status Report ===")
    enemy_log(string.format("Total enemies: %d", Util.count_keys(active_enemies)))

    local alive = 0
    local dead = 0
    local by_type = {}

    for _, enemy in pairs(active_enemies) do
        if enemy.alive then
            alive = alive + 1
        else
            dead = dead + 1
        end

        by_type[enemy.type_id] = (by_type[enemy.type_id] or 0) + 1
    end

    enemy_log(string.format("Alive: %d | Dead: %d", alive, dead))
    enemy_log("By type:")
    for type_id, count in pairs(by_type) do
        enemy_log(string.format("  %s: %d", type_id, count))
    end
end

return M
