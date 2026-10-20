-- mvtk/enemies/enemy_templates.lua
-- ============================================================================
-- Enemy Template System - Inheritance and Variants
-- ============================================================================
-- Provides a template-based enemy definition system with inheritance.
-- Create base archetypes (tank, glass cannon, healer) and derive variants.
--
-- Usage:
--   local Templates = require "mvtk.enemies.enemy_templates"
--
--   -- Register a base template
--   Templates.register("slime", { health = 2, damage = 1, behavior = "ground_patrol" })
--
--   -- Create a variant that inherits from slime
--   Templates.register("fire_slime", {
--       extends = "slime",
--       damage = 2,
--       color = {0.9, 0.3, 0.1, 1}
--   })
--
--   -- Get resolved template (with inheritance applied)
--   local fire_slime = Templates.resolve("fire_slime")

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })

local M = {}

-- Template storage
local templates = {}
local archetypes = {}

-- Debug logging
local log = Util.make_debug_log("[ENEMY_TEMPLATE]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.enemies)
end)

-- ============================================================================
-- BUILT-IN ARCHETYPES
-- ============================================================================

-- Base archetypes that define common enemy roles
archetypes = {
    -- Basic balanced enemy
    base = {
        health = 3,
        max_health = 3,
        damage = 1,
        speed = 60,
        behavior = "ground_patrol",
        detection_range = 150,
        attack_range = 80,
        attack_cooldown = 1.0,
        contact_damage = 1,
        knockback_force = 150,
        knockback_resistance = 0.2,
        invincibility_time = 0.4,
        drops = {},
        traits = {},
        weak_points = {},
    },

    -- Tank: High health, slow, high knockback resistance
    tank = {
        extends = "base",
        health = 10,
        max_health = 10,
        damage = 2,
        speed = 40,
        knockback_resistance = 0.7,
        attack_cooldown = 1.5,
        traits = {"heavy", "armored"},
    },

    -- Glass Cannon: Low health, high damage, fast
    glass_cannon = {
        extends = "base",
        health = 2,
        max_health = 2,
        damage = 3,
        speed = 100,
        knockback_resistance = 0.0,
        attack_cooldown = 0.6,
        traits = {"agile", "fragile"},
    },

    -- Ranged: Shoots projectiles
    ranged = {
        extends = "base",
        health = 4,
        max_health = 4,
        damage = 1,
        speed = 50,
        behavior = "ranged_patrol",
        shoots_projectiles = true,
        projectile_speed = 250,
        projectile_damage = 1,
        shoot_cooldown = 1.5,
        detection_range = 250,
        attack_range = 200,
        traits = {"ranged"},
    },

    -- Flyer: Aerial enemy
    flyer = {
        extends = "base",
        health = 3,
        max_health = 3,
        damage = 1,
        speed = 80,
        behavior = "flying_chase",
        hover_height = 60,
        detection_range = 180,
        knockback_resistance = 0.1,
        traits = {"flying"},
    },

    -- Charger: Rush attack enemy
    charger = {
        extends = "base",
        health = 5,
        max_health = 5,
        damage = 2,
        speed = 45,
        behavior = "charger",
        charge_speed = 300,
        charge_distance = 350,
        charge_cooldown = 2.0,
        telegraph_time = 0.6,
        knockback_resistance = 0.5,
        traits = {"heavy_hitter"},
    },

    -- Swarm: Weak individually, strong in numbers
    swarm = {
        extends = "base",
        health = 1,
        max_health = 1,
        damage = 1,
        speed = 70,
        behavior = "swarm",
        detection_range = 120,
        knockback_resistance = 0.0,
        attack_cooldown = 0.8,
        traits = {"swarm", "fragile"},
        group_behavior = true,
    },

    -- Summoner: Spawns other enemies
    summoner = {
        extends = "base",
        health = 8,
        max_health = 8,
        damage = 1,
        speed = 30,
        behavior = "summoner",
        summon_type = "swarm",
        summon_count = 3,
        summon_cooldown = 5.0,
        summon_range = 150,
        detection_range = 200,
        traits = {"summoner"},
    },

    -- Healer: Heals nearby allies
    healer = {
        extends = "base",
        health = 4,
        max_health = 4,
        damage = 1,
        speed = 55,
        behavior = "healer",
        heal_amount = 1,
        heal_cooldown = 3.0,
        heal_range = 150,
        detection_range = 200,
        traits = {"support", "priority_target"},
    },

    -- Elite: Upgraded version modifier
    elite = {
        health_multiplier = 2.0,
        damage_multiplier = 1.5,
        speed_multiplier = 1.1,
        scale_multiplier = 1.2,
        traits = {"elite"},
        color_tint = {1.0, 0.8, 0.3, 1.0},  -- Golden tint
    },

    -- Mini-boss: Strong variant
    miniboss = {
        health_multiplier = 4.0,
        damage_multiplier = 2.0,
        speed_multiplier = 0.9,
        scale_multiplier = 1.5,
        knockback_resistance = 0.8,
        traits = {"miniboss", "boss_music"},
        weak_points = {"head"},
    },
}

-- ============================================================================
-- TEMPLATE REGISTRATION
-- ============================================================================

--- Register a new enemy template
-- @param id Template identifier
-- @param definition Template definition (can include 'extends' field)
function M.register(id, definition)
    if not id or not definition then
        log("ERROR: Invalid template registration - missing id or definition")
        return false
    end

    templates[id] = definition
    log("Registered template:", id)
    return true
end

--- Register an archetype (base template for common roles)
-- @param id Archetype identifier
-- @param definition Archetype definition
function M.register_archetype(id, definition)
    archetypes[id] = definition
    log("Registered archetype:", id)
end

--- Check if template exists
-- @param id Template identifier
-- @return true if template exists
function M.exists(id)
    return templates[id] ~= nil or archetypes[id] ~= nil
end

--- Get raw template definition (without inheritance resolved)
-- @param id Template identifier
-- @return Raw template table
function M.get_raw(id)
    return templates[id] or archetypes[id]
end

-- ============================================================================
-- TEMPLATE RESOLUTION
-- ============================================================================

--- Resolve template with inheritance applied
-- @param id Template identifier
-- @return Resolved template table with all inherited properties
function M.resolve(id)
    local raw = templates[id] or archetypes[id]
    if not raw then
        log("WARNING: Template not found:", id)
        return nil
    end

    -- Start with a copy
    local resolved = Util.deep_copy(raw)

    -- Resolve inheritance chain
    local visited = {[id] = true}
    local current = raw

    while current.extends do
        local parent_id = current.extends
        if visited[parent_id] then
            log("ERROR: Circular inheritance detected:", parent_id)
            break
        end
        visited[parent_id] = true

        local parent = templates[parent_id] or archetypes[parent_id]
        if not parent then
            log("WARNING: Parent template not found:", parent_id)
            break
        end

        -- Merge parent into resolved (resolved properties take priority)
        local parent_copy = Util.deep_copy(parent)
        resolved = Util.deep_merge(parent_copy, resolved)
        current = parent
    end

    -- Remove extends field from resolved
    resolved.extends = nil

    -- Apply multipliers if present (for elite/miniboss variants)
    M.apply_multipliers(resolved)

    return resolved
end

--- Apply multipliers to template (for elite/miniboss modifiers)
-- @param template Template to modify
function M.apply_multipliers(template)
    if template.health_multiplier then
        template.health = math.floor(template.health * template.health_multiplier)
        template.max_health = template.health
    end

    if template.damage_multiplier then
        template.damage = math.floor(template.damage * template.damage_multiplier + 0.5)
        template.contact_damage = template.damage
    end

    if template.speed_multiplier then
        template.speed = math.floor(template.speed * template.speed_multiplier)
    end

    if template.scale_multiplier then
        template.scale = (template.scale or 1.0) * template.scale_multiplier
    end
end

-- ============================================================================
-- VARIANT CREATION
-- ============================================================================

--- Create a variant of an existing template
-- @param base_id Base template to extend
-- @param variant_id New variant identifier
-- @param modifications Table of property modifications
-- @return true if successful
function M.create_variant(base_id, variant_id, modifications)
    if not M.exists(base_id) then
        log("ERROR: Base template not found:", base_id)
        return false
    end

    local variant = {
        extends = base_id
    }

    -- Apply modifications
    for k, v in pairs(modifications) do
        variant[k] = v
    end

    return M.register(variant_id, variant)
end

--- Create an elite version of an enemy
-- @param base_id Base template
-- @param elite_id New elite identifier (optional, defaults to base_id .. "_elite")
-- @return true if successful
function M.create_elite(base_id, elite_id)
    elite_id = elite_id or (base_id .. "_elite")

    local elite_mod = Util.deep_copy(archetypes.elite)
    elite_mod.extends = base_id

    return M.register(elite_id, elite_mod)
end

--- Create a miniboss version of an enemy
-- @param base_id Base template
-- @param miniboss_id New miniboss identifier (optional)
-- @return true if successful
function M.create_miniboss(base_id, miniboss_id)
    miniboss_id = miniboss_id or (base_id .. "_miniboss")

    local miniboss_mod = Util.deep_copy(archetypes.miniboss)
    miniboss_mod.extends = base_id

    return M.register(miniboss_id, miniboss_mod)
end

-- ============================================================================
-- TRAIT SYSTEM
-- ============================================================================

local trait_effects = {
    -- Defense traits
    armored = { knockback_resistance = 0.3, damage_reduction = 0.2 },
    heavy = { knockback_resistance = 0.5, speed = -20 },
    fragile = { knockback_resistance = -0.2, health = -1 },

    -- Offense traits
    heavy_hitter = { damage = 1, attack_cooldown = 0.3 },
    aggressive = { chase_speed = 30, detection_range = 50 },
    berserker = { damage_at_low_health = 2.0, speed_at_low_health = 1.5 },

    -- Movement traits
    agile = { speed = 30, dodge_chance = 0.2 },
    flying = { ignores_gravity = true, ignores_ground_hazards = true },

    -- Special traits
    summoner = { can_summon = true },
    support = { can_heal = true },
    swarm = { group_bonus = true },
    regenerating = { regen_rate = 0.5 },

    -- Targeting traits
    priority_target = { ai_priority = 2 },
    elite = { boss_healthbar = false, increased_drops = true },
    miniboss = { boss_healthbar = true, arena_lock = true },
}

--- Apply trait effects to a template
-- @param template Template to modify
-- @param traits List of trait names
function M.apply_traits(template, traits)
    for _, trait in ipairs(traits) do
        local effects = trait_effects[trait]
        if effects then
            for k, v in pairs(effects) do
                if type(v) == "number" and type(template[k]) == "number" then
                    template[k] = template[k] + v
                else
                    template[k] = v
                end
            end
        end
    end
end

--- Check if template has a trait
-- @param template Resolved template
-- @param trait Trait name to check
-- @return true if template has trait
function M.has_trait(template, trait)
    if not template.traits then return false end
    for _, t in ipairs(template.traits) do
        if t == trait then return true end
    end
    return false
end

-- ============================================================================
-- QUERY FUNCTIONS
-- ============================================================================

--- Get all registered template IDs
-- @return Table of template IDs
function M.get_all_ids()
    local ids = {}
    for id, _ in pairs(templates) do
        table.insert(ids, id)
    end
    return ids
end

--- Get all archetype IDs
-- @return Table of archetype IDs
function M.get_archetype_ids()
    local ids = {}
    for id, _ in pairs(archetypes) do
        table.insert(ids, id)
    end
    return ids
end

--- Get templates by trait
-- @param trait Trait to filter by
-- @return Table of matching template IDs
function M.get_by_trait(trait)
    local matches = {}
    for id, def in pairs(templates) do
        local resolved = M.resolve(id)
        if M.has_trait(resolved, trait) then
            table.insert(matches, id)
        end
    end
    return matches
end

--- Get templates by archetype
-- @param archetype_id Archetype to filter by
-- @return Table of matching template IDs
function M.get_by_archetype(archetype_id)
    local matches = {}
    for id, def in pairs(templates) do
        if def.extends == archetype_id then
            table.insert(matches, id)
        end
    end
    return matches
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--- Initialize templates from developer config
function M.init()
    -- Load custom templates from config
    local ok, custom = pcall(require, "developer.config.enemy_templates")
    if ok and type(custom) == "table" then
        for id, def in pairs(custom) do
            M.register(id, def)
        end
        log("Loaded", Util.count_keys(custom), "custom templates from config")
    end

    -- Load enemy types and register as templates
    local ok2, types = pcall(require, "developer.config.enemy_types")
    if ok2 and type(types) == "table" then
        for id, def in pairs(types) do
            if not templates[id] then
                M.register(id, def)
            end
        end
        log("Loaded", Util.count_keys(types), "enemy types as templates")
    end
end

return M
