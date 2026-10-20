-- mvtk/tiled/spawner_registry.lua
-- Canonical Tiled object type -> handler registry.

local Util = require "mvtk.core.util"

local M = {}

-- Static requires are necessary so Defold's build system includes these files
-- in the bundle. Dynamic require(variable) calls are not statically analysed.
local MODULES = {
    { name = "collectibles", loader = require "mvtk.tiled.spawners.collectibles" },
    { name = "enemies",      loader = require "mvtk.tiled.spawners.enemies" },
    { name = "bosses",       loader = require "mvtk.tiled.spawners.bosses" },
    { name = "traversal",    loader = require "mvtk.tiled.spawners.traversal" },
    { name = "interaction",  loader = require "mvtk.tiled.spawners.interaction" },
    { name = "environment",  loader = require "mvtk.tiled.spawners.environment" },
}

local CANONICAL_BUILD_TIME_SKIP_TYPES = {
    "spawn_point",
    "boss",
    "boss_phase",
    "boss_arena",
    "arena_lock",
    "arena_boundary",
    "boss_phase_trigger",
    "boss_weak_point",
    "enemy",
    "collectible",
    "chest",
    "ability",
    "lore_item",
    "npc",
    "dialogue_trigger",
    "save_point",
    "gate",
    "health_station",
    "energy_station",
    "map_station",
    "breakable_wall",
    "light_source",
    "torch_holder",
    "pushable_block",
    "pressure_plate",
    "sign",
    "lever",
    "hint_stone",
    "one_way_platform",
    "platform",
    "moving_platform",
    "elevator",
    "elevator_node",
    "crumble_platform",
    "bounce_pad",
    "conveyor",
    "ladder",
    "teleporter",
    "timed_door",
    "wall_jump_surface",
    "grapple_point",
    "ambience_zone",
    "music_trigger",
    "particle_emitter",
    "screen_effect_zone",
    "hazard",
    "water_volume",
    "secret",
    "map_marker",
    "checkpoint",
    "fast_travel",
    "joint_platform",
    "rail_elevator",

    -- Static collision (physics templates): drop-in Solid Box objects. Its
    -- name-based synonyms are expanded by tiled_room_loader's skip aliases;
    -- keep this canonical list to handler-backed object type names only.
    "collision_box",
}

-- Baked-only static collision. Solid Slope is authored as an editable polygon
-- and baked into a per-object convex hull at build time
-- (hooks/core/tilesource.lua gen_room_object_collision). It has NO runtime
-- spawner handler, so it is kept OUT of CANONICAL_BUILD_TIME_SKIP_TYPES (which
-- asserts a handler exists) yet still counts as a recognized object type for the
-- export validator. These names resolve to collision_slope by normalized name.
local BAKED_ONLY_NO_HANDLER_TYPES = {
    -- Entire authored grapple shapes are static room resources, never
    -- spawned by a factory after the collection has loaded.
    "grapple_surface",
    "grapple_box",
    "grapple_slope",
    "object_art",
    "item_art",
    "end_game",
    -- Locked doors are fully functional baked door_blocker instances. The
    -- Tiled runtime has no factory counterpart, so the loader skips it.
    "locked_door",
    -- Solid Slope is baked into a per-object convex hull at build time.
    "collision_slope",
    "solid_slope",
    "slope",
}

-- These Tiled types deliberately keep their runtime registration path. Their
-- baked game objects are editor markers, so adding
-- them to a skip list would remove runtime data rather than prevent a second
-- game object. Keep a reason beside every exception.
local RUNTIME_REGISTRATION_ONLY_TYPES = {
    camera_zone = "The baked marker is editor-only; the runtime registers camera bounds.",
}

local SERVICE_PROVIDERS = {}

local function copy_array(values)
    local out = {}
    for i, value in ipairs(values or {}) do
        out[i] = value
    end
    return out
end

function M.register_service(name, resolver, opts)
    assert(type(name) == "string" and name ~= "", "spawner service name must be a non-empty string")
    assert(type(resolver) == "function", "spawner service resolver for '" .. name .. "' must be a function")
    opts = opts or {}
    SERVICE_PROVIDERS[name] = {
        resolver = resolver,
        init = opts.init,
        required = opts.required == true,
        value = nil,
        resolved = false,
        initialized = false,
    }
end

function M.get_service(name)
    local provider = SERVICE_PROVIDERS[name]
    if not provider then
        return nil
    end
    if provider.resolved then
        return provider.value
    end

    local ok, value = pcall(provider.resolver)
    if not ok then
        if provider.required then
            error(value, 2)
        end
        -- Keep failures retryable. This preserves the old lazy-loader behavior
        -- around optional modules and avoids permanently caching load-order races.
        return nil
    end
    if value == nil then
        if provider.required then
            error("required spawner service '" .. tostring(name) .. "' resolved to nil", 2)
        end
        -- Keep failures retryable. This preserves the old lazy-loader behavior
        -- around optional modules and avoids permanently caching load-order races.
        return nil
    end

    provider.value = value
    provider.resolved = true

    if provider.init and not provider.initialized then
        pcall(provider.init, value)
        provider.initialized = true
    end

    return provider.value
end

function M.reset_services()
    for _, provider in pairs(SERVICE_PROVIDERS) do
        provider.value = nil
        provider.resolved = false
        provider.initialized = false
    end
end

M.register_service("gate_manager", function()
    return require "mvtk.world.gates.gate_manager"
end, {
    init = function(gate_manager)
        if gate_manager and gate_manager.init then
            gate_manager.init()
        end
    end,
})

M.register_service("room_manager", function()
    return require "mvtk.map.streaming.room_manager"
end)

M.register_service("boss_arena", function()
    return require "mvtk.bosses.boss_arena"
end)

M.register_service("chest_inline_registry", function()
    return require "mvtk.world.chest_inline_registry"
end)

M.register_service("tiled_object_config", function()
    return Util.require_config("developer.config.tiled_object_config")
end, { required = true })

M.register_service("tile_settings", function()
    local defaults = { width = 128, height = 128 }
    local cfg = Util.require_config("developer.config.tile_settings")
    local w = tonumber(cfg.width or cfg.tile_width) or defaults.width
    local h = tonumber(cfg.height or cfg.tile_height) or defaults.height
    if w <= 0 then w = defaults.width end
    if h <= 0 then h = defaults.height end
    return { width = w, height = h }
end, { required = true })

local function load_domain(entry, context)
    local mod = entry.loader
    if type(mod) == "function" then
        mod = mod(context)
    end
    assert(type(mod) == "table", "spawner domain '" .. entry.name .. "' did not return a handler table")
    return mod
end

function M.build(context)
    local handlers = {}
    local owners = {}

    for _, entry in ipairs(MODULES) do
        local domain_handlers = load_domain(entry, context)
        for object_type, handler in pairs(domain_handlers) do
            assert(type(handler) == "function", string.format(
                "spawner handler '%s' from %s is not a function",
                tostring(object_type), entry.name))
            assert(handlers[object_type] == nil, string.format(
                "spawner object type '%s' mapped by both %s and %s",
                tostring(object_type), tostring(owners[object_type]), entry.name))
            handlers[object_type] = handler
            owners[object_type] = entry.name
        end
    end

    for _, object_type in ipairs(CANONICAL_BUILD_TIME_SKIP_TYPES) do
        assert(handlers[object_type] ~= nil,
            "canonical build-time object type missing runtime spawner handler: " .. tostring(object_type))
    end

    return handlers, owners
end

function M.install(spawner, context)
    assert(type(spawner) == "table", "spawner_registry.install requires the spawner module table")
    if spawner._registry_handlers_loaded then
        return spawner.handlers
    end

    context = context or (spawner.get_handler_context and spawner.get_handler_context())
    local handlers, owners = M.build(context)

    local existing = spawner.handlers or {}
    for object_type, handler in pairs(existing) do
        if handlers[object_type] == nil then
            handlers[object_type] = handler
            owners[object_type] = "custom"
        end
    end

    spawner.handlers = handlers
    spawner._handler_owners = owners
    spawner._registry_handlers_loaded = true
    spawner._external_handlers_loaded = true
    return handlers
end

function M.get_modules()
    return copy_array(MODULES)
end

function M.get_canonical_build_time_skip_types()
    local out = copy_array(CANONICAL_BUILD_TIME_SKIP_TYPES)
    -- Baked-only types have no runtime handler but are still valid object types
    -- the export validator must accept (e.g. collision_slope / Solid Slope).
    for _, object_type in ipairs(BAKED_ONLY_NO_HANDLER_TYPES) do
        out[#out + 1] = object_type
    end
    return out
end

function M.get_baked_only_no_handler_types()
    return copy_array(BAKED_ONLY_NO_HANDLER_TYPES)
end

function M.get_runtime_registration_only_types()
    local out = {}
    for object_type, reason in pairs(RUNTIME_REGISTRATION_ONLY_TYPES) do
        out[object_type] = reason
    end
    return out
end

-- Enumerate registered service names. Optionally restrict to required services.
-- Returns an array of strings (sorted for stable diagnostics).
function M.list_services(opts)
    opts = opts or {}
    local only_required = opts.required_only == true
    local names = {}
    for name, provider in pairs(SERVICE_PROVIDERS) do
        if (not only_required) or provider.required then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- Verify every required service can be resolved. Returns ok, missing_list, errors_list.
-- This is the strict tooling-side check used by tools/validate_tiled_export.lua and
-- the editor build hook. Runtime callers should use M.get_service() directly so a
-- single bad service does not crash the whole game.
function M.verify_required_services()
    local missing = {}
    local errors = {}
    for name, provider in pairs(SERVICE_PROVIDERS) do
        if provider.required then
            local ok, err_or_value = pcall(provider.resolver)
            if not ok then
                errors[#errors + 1] = string.format("%s: %s", name, tostring(err_or_value))
                missing[#missing + 1] = name
            elseif err_or_value == nil then
                missing[#missing + 1] = name
            end
        end
    end
    table.sort(missing)
    table.sort(errors)
    return (#missing == 0 and #errors == 0), missing, errors
end

return M
