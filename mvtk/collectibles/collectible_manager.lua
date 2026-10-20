--- Collectible Manager
-- Central controller for all collectibles and secrets
-- Handles spawning, collection, persistence, and tracking
--
-- @module collectible_manager

local Util = require "mvtk.core.util"
local SafeSound = require "mvtk.audio.safe_sound"
local KeyIds = require "mvtk.core.key_ids"

local M = {}

local Time = require "mvtk.core.time"
local Config = Util.require_config("developer.config.resolved_config")
local collectible_types = Util.require_config("developer.config.collectible_types")
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })
local C = require "mvtk.core.constants"

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local function print(...)  -- luacheck: ignore 121
    if Debug.collectibles and Debug.collectibles.pickup then
        _orig_print(...)
    end
end

-- Build hash-to-string reverse lookup for collectible types
local collectible_type_hash_to_string = {}
for key, _ in pairs(collectible_types) do
    collectible_type_hash_to_string[hash(key)] = key
end

--- Convert collectible type (hash or string) to string key
-- @param type_id Hash or string type identifier
-- @return string key or nil
local function resolve_type_key(type_id)
    if type(type_id) == "userdata" then
        -- It's a hash, look up string key
        return collectible_type_hash_to_string[type_id]
    end
    -- Already a string
    return type_id
end

local normalize_ability_id = Util.normalize_ability_id

local normalize_flag_name = Util.normalize_hash_string

local function get_player_message_targets()
    local targets = {}
    local base_targets = {
        C.URL.PLAYER,
    }
    for _, entry in ipairs(base_targets) do
        if entry then
            local ok_url, u = pcall(msg.url, entry)
            if ok_url and u then
                local go_url = msg.url(u.socket, u.path, nil)
                local ok_exists, exists = pcall(go.exists, go_url)
                if ok_exists and exists then
                    targets[#targets + 1] = msg.url(u.socket, u.path, hash("script"))
                end
            end
        end
    end

    local deduped = {}
    local seen = {}
    for _, target in ipairs(targets) do
        local key = tostring(target)
        if target and not seen[key] then
            seen[key] = true
            deduped[#deduped + 1] = target
        end
    end
    return deduped
end

local function post_to_player(message_id, payload)
    local sent = false
    for _, target in ipairs(get_player_message_targets()) do
        local ok = pcall(msg.post, target, message_id, payload)
        if ok then
            sent = true
        end
    end
    return sent
end

local function post_grant_ability_to_player(ability_id, enabled)
    local ok_const, constants = pcall(require, "mvtk.core.constants")
    local msg_id = (ok_const and constants.MSG and constants.MSG.GRANT_ABILITY) or hash("mvtk_grant_ability")
    post_to_player(msg_id, {
        ability = ability_id,
        enabled = enabled and true or false,
    })
end

local function ability_debug(...)
    if Debug.global.enable or Debug.gameplay.ability_manager or (Debug.collectibles and Debug.collectibles.pickup) then
        print(...)
    end
end

local function infer_fallback_type(type_key, cfg)
    local key = type_key and tostring(type_key) or ""
    if key:match("^relic_") then
        return "relic"
    end

    if type(cfg) == "table" then
        local relic_id = cfg.relic_id
        if type(relic_id) == "string" and relic_id ~= "" then
            return "relic"
        end
    end

    return nil
end

-- Storage
local active_collectibles = {}  -- collectible_id -> {type, position, config, game_object_url}
local collected_items = {}  -- Set of collected collectible IDs
local discovered_secrets = {}  -- Set of discovered secret IDs
local room_collectibles = {}  -- room_id -> {collectible_id, ...}
local registered_secrets = {}  -- Set of all possible secret IDs (for completion tracking)
local pending_spawns = {}     -- Temporary guard to prevent duplicate spawns in the same frame

-- Completion tracking
local completion_data = {
    per_room = {},  -- room_id -> {total, collected}
    per_area = {},  -- area_id -> {total, collected}
}

-- Configuration
local config = {
    save_prefix = "collected_",  -- Prefix for flag names
    use_flags = true,  -- Use Flags system for persistence
}

local function is_collectible_autosave_enabled()
    local saves = Config and Config.progression and Config.progression.saves
    return saves and saves.autosave_on_collectible_pickup == true
end

function M.autosave_after_collect(reason)
    if not is_collectible_autosave_enabled() then
        return false
    end

    local ok_cp, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if not ok_cp or not Checkpoint or not Checkpoint.autosave then
        print("[COLLECTIBLE_MANAGER] Warning: Checkpoint autosave unavailable for collectible pickup")
        return false
    end

    local ok_save, err = pcall(Checkpoint.autosave, reason or "collectible_pickup")
    if not ok_save then
        print(string.format("[COLLECTIBLE_MANAGER] Warning: collectible autosave failed (%s)", tostring(err)))
        return false
    end

    return true
end

--- Initialize collectible manager
-- @param custom_config Optional configuration overrides
function M.init(custom_config)
    if custom_config then
        for k, v in pairs(custom_config) do
            config[k] = v
        end
    end

    -- Start each game session from a clean runtime state, then rebuild
    -- collected items from the currently active save/flags payload.
    M.reset()

    -- Load collected items from save
    M.load_from_save()

    print("[COLLECTIBLE_MANAGER] Initialized")
end

--- Load collected items from save system
function M.load_from_save()
    -- Rebuild collected state from the active save payload instead of
    -- accumulating stale in-memory entries from a previous session/slot.
    collected_items = {}

    if not config.use_flags then
        return
    end

    -- Try to load Flags system
    local success, Flags = pcall(require, "mvtk.core.flags")
    if not success then
        print("[COLLECTIBLE_MANAGER] Flags system not available, persistence disabled")
        config.use_flags = false
        return
    end

    -- If flags provider was registered after checkpoint load, the runtime Flags table
    -- may still be empty. Hydrate it directly from checkpoint data as a fallback.
    if Flags.all and Flags.import then
        local existing = Flags.all()
        if type(existing) == "table" and next(existing) == nil then
            local ok_cp, Checkpoint = pcall(require, "mvtk.core.checkpoint")
            local checkpoint_flags = nil
            if ok_cp and Checkpoint and type(Checkpoint.data) == "table" then
                local modules = Checkpoint.data.modules
                local flags_module = (type(modules) == "table") and modules.flags or nil
                if type(flags_module) == "table" and type(flags_module.data) == "table" then
                    checkpoint_flags = flags_module.data
                elseif type(Checkpoint.data.flags) == "table" then
                    checkpoint_flags = Checkpoint.data.flags
                end
            end

            if checkpoint_flags then
                local ok_import, err_import = pcall(Flags.import, checkpoint_flags)
                if ok_import then
                    print("[COLLECTIBLE_MANAGER] Hydrated Flags from checkpoint payload")
                else
                    print(string.format("[COLLECTIBLE_MANAGER] Failed to hydrate Flags: %s", tostring(err_import)))
                end
            end
        end
    end

    -- Load all collected items from flags
    -- Scan all flags with the save_prefix to rebuild collected_items
    if Flags.all then
        local all_flags = Flags.all()
        for flag_name, value in pairs(all_flags) do
            local flag_key = normalize_flag_name(flag_name)
            -- Match flags with the save_prefix (e.g., "collected_")
            if flag_key and flag_key:match("^" .. config.save_prefix) and value then
                local collectible_id = flag_key:gsub("^" .. config.save_prefix, "")
                collected_items[collectible_id] = true
            end
        end
    end

    print("[COLLECTIBLE_MANAGER] Loaded collected items from save")
end

--- Save collected item to save system
-- @param collectible_id Collectible identifier
function M.save_collected(collectible_id)
    if not config.use_flags then
        return
    end

    local success, Flags = pcall(require, "mvtk.core.flags")
    if not success then
        return
    end

    local flag_name = config.save_prefix .. collectible_id
    Flags.set(flag_name, true)
end

--- Spawn a collectible in the world
-- @param collectible_type Type from collectible_types.lua
-- @param position World position vector3
-- @param custom_config Optional config overrides
-- @return collectible_id or nil if failed
function M.spawn_collectible(collectible_type, position, custom_config)
    local cfg = custom_config or {}
    local trace_enabled = Debug.collectibles and Debug.collectibles.pickup
    local px, py, flag_text
    if trace_enabled then
        local caller = debug.getinfo(2, "Sl")
        local caller_desc = caller and string.format("%s:%d", caller.short_src or caller.source, caller.currentline or -1) or "<unknown>"
        local flags = {}
        if cfg.room_id then table.insert(flags, string.format("room=%s", tostring(cfg.room_id))) end
        if cfg.spawned_from_tile then table.insert(flags, "tilemap") end
        if cfg.spawned_from_door_lock then table.insert(flags, "door_lock") end
        if cfg.spawned_from_scanner then table.insert(flags, "scanner") end
        if cfg.from_factory then table.insert(flags, "factory") end
        flag_text = #flags > 0 and table.concat(flags, ",") or "none"
        local id_hint = cfg.id and tostring(cfg.id) or "<auto>"
        px = position and position.x or 0
        py = position and position.y or 0
        print(string.format("[COLLECTIBLE_MANAGER][TRACE] request type=%s pos=(%.1f, %.1f) id_hint=%s flags=[%s] caller=%s",
            tostring(collectible_type), px, py, id_hint, flag_text, caller_desc))
    end

    -- Resolve hash to string key if needed
    local type_key = resolve_type_key(collectible_type)
    if not type_key then
        print(string.format("[COLLECTIBLE_MANAGER] ERROR: Could not resolve collectible type hash: %s", tostring(collectible_type)))
        return nil
    end

    -- Get type definition using resolved string key
    local type_def = collectible_types[type_key]
    local fallback_type = nil
    if not type_def then
        fallback_type = infer_fallback_type(type_key, custom_config)
        if fallback_type then
            type_def = collectible_types[fallback_type]
        end
    end

    if not type_def then
        local valid_types = {}
        for type_name, _ in pairs(collectible_types) do
            valid_types[#valid_types + 1] = type_name
        end
        table.sort(valid_types)
        
        print("[COLLECTIBLE_MANAGER] ========== ERROR: UNKNOWN COLLECTIBLE TYPE ==========")
        print(string.format("[COLLECTIBLE_MANAGER] Type '%s' is not defined in collectible_types.lua", tostring(type_key)))
        print("[COLLECTIBLE_MANAGER] Valid types are:")
        for _, name in ipairs(valid_types) do
            print("[COLLECTIBLE_MANAGER]   - " .. name)
        end
        print("[COLLECTIBLE_MANAGER] ====================================================")
        print("[COLLECTIBLE_MANAGER] TIP: Add this type to developer/config/collectible_types.lua")
        return nil
    end

    if fallback_type then
        print(string.format("[COLLECTIBLE_MANAGER] Using fallback type '%s' for authored type '%s'",
            tostring(fallback_type), tostring(type_key)))
    end

    -- Generate unique ID
    local collectible_id = cfg.id or M.generate_id(type_key, position)

    -- Check if already collected
    if M.is_collected(collectible_id) then
        print(string.format("[COLLECTIBLE_MANAGER][TRACE] skip_spawn already collected id=%s type=%s", collectible_id, tostring(collectible_type)))
        return nil
    end

    -- Prevent duplicate spawns racing in the same frame (object layer + tile scanner, etc.)
    if pending_spawns[collectible_id] or active_collectibles[collectible_id] then
        print(string.format("[COLLECTIBLE_MANAGER][TRACE] skip_spawn duplicate id=%s type=%s", collectible_id, tostring(collectible_type)))
        return nil
    end
    pending_spawns[collectible_id] = true

    -- Merge configs
    local final_config = {}
    for k, v in pairs(type_def) do
        final_config[k] = v
    end
    if custom_config then
        for k, v in pairs(custom_config) do
            final_config[k] = v
        end
    end
    if final_config.item_id ~= nil then
        final_config.item_id = KeyIds.canonicalize(final_config.item_id) or final_config.item_id
    end

    -- Store collectible data (use resolved string key for type)
    active_collectibles[collectible_id] = {
        id = collectible_id,
        type = type_key,
        base_type = fallback_type or type_key,
        position = position,
        config = final_config,
        room_id = custom_config and custom_config.room_id,
        spawned_time = Time.gettime(),
    }

    -- Track by room
    if cfg.room_id then
        local room_id = cfg.room_id
        room_collectibles[room_id] = room_collectibles[room_id] or {}
        table.insert(room_collectibles[room_id], collectible_id)

        -- Update completion tracking
        M.update_room_completion(room_id)
    end

    -- Spawn game object (if using factory pattern)
    -- This would be handled by the collectible.script component
    -- For now, we just track the data

    if trace_enabled then
        print(string.format("[COLLECTIBLE_MANAGER][TRACE] spawned id=%s type=%s pos=(%.1f, %.1f) flags=[%s]",
            collectible_id, tostring(collectible_type), px, py, flag_text))
    end

    pending_spawns[collectible_id] = nil
    return collectible_id
end

--- Collect a collectible
-- @param collectible_id Collectible identifier
-- @param collector_id Who collected it (usually "player")
-- @return true if successfully collected
function M.collect(collectible_id, collector_id)
    local collectible = active_collectibles[collectible_id]

    if not collectible then
        print("[COLLECTIBLE_MANAGER] Collectible not found:", collectible_id)
        return false
    end

    if M.is_collected(collectible_id) then
        print("[COLLECTIBLE_MANAGER] Already collected:", collectible_id)
        return false
    end

    local respawns = collectible.config and collectible.config.respawns == true

    -- Rejected/failed rewards must leave the pickup available.
    if collectible.collecting then return false end
    collectible.collecting = true
    local ok, result = pcall(M.execute_collection_behavior, collectible, collector_id)
    collectible.collecting = nil
    if not ok then
        print("[COLLECTIBLE_MANAGER] Reward failed: " .. tostring(result))
        return false
    end
    if result == false then return false end
    -- Mark as collected (session)
    collected_items[collectible_id] = true

    -- Save to persistence unless respawnable
    if not respawns then
        M.save_collected(collectible_id)
    end

    -- Update completion tracking
    if collectible.room_id then
        M.update_room_completion(collectible.room_id)
    end

    M.autosave_after_collect("collectible_pickup")

    print(string.format("[COLLECTIBLE_MANAGER] Collected %s (%s)", collectible_id, collectible.type))

    return true
end

--- Execute collection behavior (what happens when collected)
-- @param collectible Collectible data
-- @param collector_id Who collected it
function M.execute_collection_behavior(collectible, collector_id)
    local config = collectible.config
    local behavior = config.on_collect

    if not behavior then
        return
    end

    -- Handle different behavior types
    if behavior == "restore_health" then
        M.restore_health(config.value or 5)

    elseif behavior == "restore_energy" then
        M.restore_energy(config.value or 5)

    elseif behavior == "increase_max_health" then
        M.increase_max_health(config.value or 1)

    elseif behavior == "increase_max_energy" then
        M.increase_max_energy(config.value or 10)

    elseif behavior == "increase_max_stamina" then
        M.increase_max_stamina(config.value or 1)

    elseif behavior == "reveal_map_area" then
        M.reveal_map_area(config.area_id, config.area_name)

    elseif behavior == "add_to_inventory" then
        local count = tonumber(config.count or config.amount or 1) or 1
        M.add_to_inventory(config.item_id, count)

    elseif behavior == "add_to_collection" then
        M.add_to_collection(config.relic_id, config)

    elseif behavior == "unlock_lore_entry" then
        M.unlock_lore(config.lore_id, config.lore_text)

    elseif behavior == "reveal_nearby" or behavior == "reveal_map_fragment" then
        local radius = tonumber(config.reveal_radius or config.radius or config.value) or 0
        M.reveal_nearby_rooms(collectible and collectible.position, radius, config)
        if config.area_id then
            M.reveal_map_area(config.area_id, config.area_name)
        end

    elseif behavior == "add_currency" then
        M.add_currency(config.currency_type, config.value)

    elseif behavior == "unlock_ability" then
        local ability_id = config.ability_id
        if not ability_id or ability_id == "" then
            local type_key = collectible and collectible.type
            if type(type_key) == "string" then
                ability_id = type_key:match("^ability_(.+)$")
            end
        end
        local id = normalize_ability_id(ability_id)
        if not id or id == "" then
            print(string.format("[COLLECTIBLE_MANAGER] Missing ability_id for collectible %s",
                tostring((collectible and (collectible.id or collectible.type)) or "unknown")))
            return false
        end

        ability_debug(string.format("[COLLECTIBLE_MANAGER] Unlock ability id=%s collectible=%s",
            tostring(id), tostring((collectible and (collectible.id or collectible.type)) or "unknown")))
        local ok_prog, Progression = pcall(require, "mvtk.game.progression.progression_manager")
        if ok_prog and Progression and Progression.unlock_ability then
            Progression.unlock_ability(id, { enabled = true, source = "pickup" })
        else
            local ok_am, AbilityManager = pcall(require, "mvtk.abilities.ability_manager")
            if ok_am and AbilityManager and AbilityManager.unlock_ability then
                AbilityManager.unlock_ability(id, { enabled = true })
            end
        end
        local ok_state, AbilityManager = pcall(require, "mvtk.abilities.ability_manager")
        if ok_state and AbilityManager and AbilityManager.get_ability_info then
            local info = AbilityManager.get_ability_info(id)
            if info then
                ability_debug(string.format("[COLLECTIBLE_MANAGER] Ability state id=%s unlocked=%s enabled=%s",
                    tostring(id), tostring(info.unlocked), tostring(info.enabled)))
            else
                ability_debug(string.format("[COLLECTIBLE_MANAGER] Ability state id=%s info=missing", tostring(id)))
            end
        end

        -- Ask the player to refresh ability-driven movement/state immediately.
        post_grant_ability_to_player(id, true)

    elseif type(behavior) == "function" then
        -- Custom function
        if behavior(collectible, collector_id) == false then return false end
    end

    if config.show_popup then
        local title = config.popup_title or config.notification or ""
        local description = config.popup_description or ""
        local duration = config.popup_duration or 4.0
        if title ~= "" or description ~= "" then
            local hud_url = (C and C.url and C.url("MODE_HUD")) or msg.url("main:/mode_hud#mode_hud")
            pcall(msg.post, hud_url, hash("show_tutorial"), {
                title = title,
                description = description,
                duration = duration,
            })
        end
    end

    -- Show notification
    if config.notification then
        M.show_notification(config.notification, config.popup_duration or 2.0)
    end

    -- Play collection sound
    if config.audio and config.audio.collect then
        SafeSound.play(config.audio.collect)
    end
end

--- Check if collectible is already collected
-- @param collectible_id Collectible identifier
-- @return true if collected
function M.is_collected(collectible_id)
    return collected_items[collectible_id] == true
end

--- Get collectible data
-- @param collectible_id Collectible identifier
-- @return Collectible data or nil
function M.get_collectible(collectible_id)
    return active_collectibles[collectible_id]
end

--- Remove an active collectible registration without marking it collected.
-- Used when a spawned prefab initially registers with a provisional/generated id
-- and is then rebound to its authored Tiled id.
-- @param collectible_id Collectible identifier
-- @return true if a registration was removed
function M.unregister_collectible(collectible_id)
    if not collectible_id or collectible_id == "" then
        return false
    end

    pending_spawns[collectible_id] = nil

    local collectible = active_collectibles[collectible_id]
    if not collectible then
        return false
    end

    active_collectibles[collectible_id] = nil

    local room_id = collectible.room_id
    if room_id and room_collectibles[room_id] then
        local updated = {}
        for _, id in ipairs(room_collectibles[room_id]) do
            if id ~= collectible_id then
                updated[#updated + 1] = id
            end
        end
        room_collectibles[room_id] = updated
        M.update_room_completion(room_id)
    end

    return true
end

--- Get all collectibles in a room
-- @param room_id Room identifier
-- @return Table of collectible IDs
function M.get_room_collectibles(room_id)
    return room_collectibles[room_id] or {}
end

--- Get uncollected collectibles in a room
-- @param room_id Room identifier
-- @return Table of collectible IDs
function M.get_uncollected_in_room(room_id)
    local uncollected = {}
    local collectibles = M.get_room_collectibles(room_id)

    for _, collectible_id in ipairs(collectibles) do
        if not M.is_collected(collectible_id) then
            table.insert(uncollected, collectible_id)
        end
    end

    return uncollected
end

--- Unload room collectibles
-- @param room_id Room identifier
function M.unload_room(room_id)
    local collectibles = room_collectibles[room_id]
    if not collectibles then
        return
    end

    local count = 0
    for _, collectible_id in ipairs(collectibles) do
        local collectible = active_collectibles[collectible_id]
        if collectible then
            if collectible.config and collectible.config.respawns == true then
                collected_items[collectible_id] = nil
            end
            -- Remove from active (but keep in collected if collected)
            active_collectibles[collectible_id] = nil
            count = count + 1
        end
    end

    print(string.format("[COLLECTIBLE_MANAGER] Unloaded %d collectibles from room %s", count, room_id))
end

--- Generate unique collectible ID
-- @param collectible_type Type name
-- @param position Position vector
-- @return Unique ID string
function M.generate_id(collectible_type, position)
    local x = math.floor(position.x)
    local y = math.floor(position.y)
    local timestamp = math.floor(Time.gettime() * 1000)
    return string.format("%s_%d_%d_%d", collectible_type, x, y, timestamp)
end

--[[========================================================================
    COMPLETION TRACKING
========================================================================]]

--- Update room completion tracking
-- @param room_id Room identifier
function M.update_room_completion(room_id)
    local collectibles = room_collectibles[room_id]
    if not collectibles then
        completion_data.per_room[room_id] = {total = 0, collected = 0, percentage = 0}
        return
    end

    local total = #collectibles
    local collected = 0

    for _, collectible_id in ipairs(collectibles) do
        if M.is_collected(collectible_id) then
            collected = collected + 1
        end
    end

    local percentage = total > 0 and (collected / total * 100) or 0

    completion_data.per_room[room_id] = {
        total = total,
        collected = collected,
        percentage = percentage,
    }
end

--- Get room completion percentage
-- @param room_id Room identifier
-- @return {total, collected, percentage}
function M.get_room_completion(room_id)
    M.update_room_completion(room_id)
    return completion_data.per_room[room_id] or {total = 0, collected = 0, percentage = 0}
end

--- Get area completion (sum of all rooms in area)
-- @param area_id Area identifier
-- @param room_ids Table of room IDs in this area
-- @return {total, collected, percentage}
function M.get_area_completion(area_id, room_ids)
    local total = 0
    local collected = 0

    for _, room_id in ipairs(room_ids) do
        local room_data = M.get_room_completion(room_id)
        total = total + room_data.total
        collected = collected + room_data.collected
    end

    local percentage = total > 0 and (collected / total * 100) or 0

    return {
        total = total,
        collected = collected,
        percentage = percentage,
    }
end

--- Get global completion
-- @return {total_collectibles, collected, percentage, secrets_found, total_secrets}
function M.get_global_completion()
    local total = 0
    local collected = 0

    for room_id, _ in pairs(room_collectibles) do
        local room_data = M.get_room_completion(room_id)
        total = total + room_data.total
        collected = collected + room_data.collected
    end

    local percentage = total > 0 and (collected / total * 100) or 0

    -- Count secrets
    local secrets_found = 0
    for _ in pairs(discovered_secrets) do
        secrets_found = secrets_found + 1
    end

    -- Count total registered secrets
    local total_secrets = 0
    for _ in pairs(registered_secrets) do
        total_secrets = total_secrets + 1
    end

    return {
        total_collectibles = total,
        collected = collected,
        percentage = percentage,
        secrets_found = secrets_found,
        total_secrets = total_secrets,
    }
end

--[[========================================================================
    COLLECTION BEHAVIORS (Integration Points)
========================================================================]]

--- Restore health (consumables)
-- @param amount Amount to restore
function M.restore_health(amount)
    print(string.format("[COLLECTIBLE_MANAGER] Health +%d", amount))

    local success = post_to_player(hash("mvtk_restore_health"), { amount = amount })

    if not success then
        print("[COLLECTIBLE_MANAGER] Warning: Could not send health restore to player")
    end
end

--- Restore energy (consumables)
-- @param amount Amount to restore
function M.restore_energy(amount)
    print(string.format("[COLLECTIBLE_MANAGER] Energy +%d", amount))

    local success = post_to_player(hash("mvtk_restore_energy"), { amount = amount })

    if not success then
        print("[COLLECTIBLE_MANAGER] Warning: Could not send energy restore to player")
    end
end

--- Increase max health
-- @param amount Amount to increase
function M.increase_max_health(amount)
    print(string.format("[COLLECTIBLE_MANAGER] Max health +%d", amount))

    local success = post_to_player(hash("mvtk_increase_max_health"), { amount = amount })

    if not success then
        print("[COLLECTIBLE_MANAGER] Warning: Could not send max health increase to player")
    end
end

--- Increase max energy
-- @param amount Amount to increase
function M.increase_max_energy(amount)
    print(string.format("[COLLECTIBLE_MANAGER] Max energy +%d", amount))

    local success = post_to_player(hash("mvtk_increase_max_energy"), { amount = amount })

    if not success then
        print("[COLLECTIBLE_MANAGER] Warning: Could not send max energy increase to player")
    end
end

--- Increase max stamina
-- @param amount Amount to increase
function M.increase_max_stamina(amount)
    print(string.format("[COLLECTIBLE_MANAGER] Max stamina +%d", amount))

    local success = post_to_player(hash("mvtk_increase_max_stamina"), { amount = amount })

    if not success then
        print("[COLLECTIBLE_MANAGER] Warning: Could not send max stamina increase to player")
    end
end

--- Reveal map area
-- @param area_id Area identifier
-- @param area_name Area display name
function M.reveal_map_area(area_id, area_name)
    print(string.format("[COLLECTIBLE_MANAGER] Revealing map area: %s", area_name))

    -- Use Flags to track revealed areas (persistence)
    local success, Flags = pcall(require, "mvtk.core.flags")
    if success and Flags then
        Flags.set("map_revealed_" .. area_id, true)
    end

    -- Send update message to world map GUI
    local world_map_url = msg.url("main:/world_map_gui#world_map")
    local map_success = pcall(msg.post, world_map_url, hash("reveal_area"), {area_id = area_id})

    if not map_success then
        print("[COLLECTIBLE_MANAGER] Warning: Could not send reveal_area to world map (GUI not found)")
    end
end

--- Add item to inventory
-- @param item_id Item identifier
function M.add_to_inventory(item_id, count)
    item_id = KeyIds.canonicalize(item_id) or item_id
    print(string.format("[COLLECTIBLE_MANAGER] Adding to inventory: %s", item_id))

    -- Integrate with existing inventory system
    local success, Inventory = pcall(require, "mvtk.core.inventory")
    if success and Inventory and Inventory.add_item then
        Inventory.add_item(item_id, count or 1)
    else
        print("[COLLECTIBLE_MANAGER] Warning: Inventory system not available")
    end
end

--- Reveal nearby rooms on the minimap
-- @param position World position vector3
-- @param radius Radius in world units
-- @param opts Optional config (unused, reserved)
function M.reveal_nearby_rooms(position, radius, opts)
    if not position then return end
    local r = tonumber(radius) or 0
    if r <= 0 then return end

    local mini = rawget(_G, "MINIMAP_MODULE")
    if mini and mini.reveal_rooms_near then
        mini.reveal_rooms_near(position, r, opts)
        return
    end

    if mini and mini.explored and mini.center_id then
        mini.explored[mini.center_id] = true
    end
end

--- Add relic to collection
-- @param relic_id Relic identifier
-- @param relic_data Relic data (name, description, etc.)
function M.add_to_collection(relic_id, relic_data)
    print(string.format("[COLLECTIBLE_MANAGER] Relic collected: %s", relic_data.name))

    -- Save relic to Flags system
    if config.use_flags then
        local success, Flags = pcall(require, "mvtk.core.flags")
        if success and Flags then
            Flags.set("collected_relic_" .. relic_id, true)
            -- Store relic data as JSON string
            local json_ok, json = pcall(require, "json")
            if json_ok and json then
                Flags.set("relic_data_" .. relic_id, json.encode(relic_data))
            end
        end
    end

    -- Show notification with relic name
    M.show_notification("Relic Found: " .. (relic_data.name or relic_id), 3.0)
end

--- Unlock lore entry
-- @param lore_id Lore identifier
-- @param lore_text Lore text content
function M.unlock_lore(lore_id, lore_text)
    print(string.format("[COLLECTIBLE_MANAGER] Lore unlocked: %s", lore_id))

    -- Save lore to Flags system
    if config.use_flags then
        local success, Flags = pcall(require, "mvtk.core.flags")
        if success and Flags then
            Flags.set("collected_lore_" .. lore_id, true)
            Flags.set("lore_text_" .. lore_id, lore_text or "")
        end
    end

    -- Show notification
    M.show_notification("Lore Entry Unlocked!", 2.5)
end

--- Get all collected relics
-- @return Table of relic IDs
function M.get_collected_relics()
    local relics = {}

    if not config.use_flags then
        return relics
    end

    local success, Flags = pcall(require, "mvtk.core.flags")
    if not success or not Flags then
        return relics
    end

    -- Scan all flags for collected relics
    if Flags.all then
        local all_flags = Flags.all()
        for flag_name, value in pairs(all_flags) do
            local flag_key = normalize_flag_name(flag_name)
            -- Match flags with "collected_relic_" prefix
            if flag_key and flag_key:match("^collected_relic_") and value then
                local relic_suffix = flag_key:gsub("^collected_relic_", "")
                -- Reconstruct the full type key (e.g., "ancient_sword" -> "relic_ancient_sword")
                local relic_id = "relic_" .. relic_suffix

                -- Look up relic data from collectible_types
                local type_data = collectible_types[relic_id]
                if type_data and type_data.category == "relic" then
                    table.insert(relics, {
                        id = relic_id,
                        type_key = relic_id,
                        name = type_data.name or relic_id,
                        description = type_data.description or "",
                        icon = type_data.sprite or "",
                        animation = type_data.animation or "idle"
                    })
                else
                    -- Fallback for unknown relics
                    table.insert(relics, {
                        id = relic_id,
                        type_key = relic_id,
                        name = relic_id,
                        description = "Unknown relic",
                        icon = "",
                        animation = "idle"
                    })
                end
            end
        end
    end

    return relics
end

--- Get all collected lore entries
-- @return Table of lore objects
function M.get_collected_lore()
    local lore = {}

    if not config.use_flags then
        return lore
    end

    local success, Flags = pcall(require, "mvtk.core.flags")
    if not success or not Flags then
        return lore
    end

    local function lookup_type_data(lore_suffix)
        local direct_id = lore_suffix
        local lore_id = lore_suffix
        if not lore_id:match("^lore_") then
            lore_id = "lore_" .. lore_suffix
        end

        local type_data = collectible_types[lore_id]
        if type_data and type_data.category == "lore" then
            return lore_id, type_data
        end

        type_data = collectible_types[direct_id]
        if type_data and type_data.category == "lore" then
            return direct_id, type_data
        end

        return lore_id, nil
    end

    local function flag_get(key, default)
        if Flags and Flags.get then
            return Flags.get(key, default)
        end
        return default
    end

    -- Scan all flags for collected lore entries
    if Flags.all then
        local all_flags = Flags.all()
        for flag_name, value in pairs(all_flags) do
            local flag_key = normalize_flag_name(flag_name)
            -- Match flags with "collected_lore_" prefix
            if flag_key and flag_key:match("^collected_lore_") and value then
                local lore_suffix = flag_key:gsub("^collected_lore_", "")
                local lore_id, type_data = lookup_type_data(lore_suffix)
                local saved_text = tostring(flag_get("lore_text_" .. lore_suffix, "") or "")
                local saved_title = tostring(flag_get("lore_title_" .. lore_suffix, "") or "")
                local saved_category = tostring(flag_get("lore_category_" .. lore_suffix, "") or "")

                if type_data and type_data.category == "lore" then
                    table.insert(lore, {
                        id = lore_id,
                        type_key = lore_id,
                        name = saved_title ~= "" and saved_title or (type_data.name or lore_id),
                        description = type_data.description or saved_title or "",
                        text = saved_text ~= "" and saved_text or (type_data.lore_text or type_data.description or ""),
                        icon = type_data.sprite or "",
                        animation = type_data.animation or "idle",
                        category = saved_category ~= "" and saved_category or (type_data.category or "lore"),
                    })
                else
                    -- Fallback for unknown lore
                    table.insert(lore, {
                        id = lore_suffix,
                        type_key = lore_suffix,
                        name = saved_title ~= "" and saved_title or lore_suffix,
                        description = "Lore entry",
                        text = saved_text,
                        icon = "",
                        animation = "idle",
                        category = saved_category ~= "" and saved_category or "lore",
                    })
                end
            end
        end
    end

    return lore
end

--- Add currency
-- @param currency_type Type of currency
-- @param amount Amount to add
function M.add_currency(currency_type, amount)
    print(string.format("[COLLECTIBLE_MANAGER] Currency +%d %s", amount, currency_type))

    -- Integrate with existing inventory currency system
    local success, Inventory = pcall(require, "mvtk.core.inventory")
    if success and Inventory and Inventory.add_currency then
        Inventory.add_currency(amount)
    else
        print("[COLLECTIBLE_MANAGER] Warning: Currency system not available")
    end
end

--- Show notification to player
-- @param message Notification text
-- @param duration Duration in seconds
function M.show_notification(message, duration)
    print(string.format("[COLLECTIBLE_MANAGER] NOTIFICATION: %s", message))

    -- Integrate with existing toast notification system
    local toast_url = msg.url("main:/toast_gui#toast")
    local success = pcall(msg.post, toast_url, hash("toast"), {
        message = message,
        duration = duration or 2.0
    })

    if not success then
        print("[COLLECTIBLE_MANAGER] Warning: Toast notification system not available")
    end
end

--[[========================================================================
    SECRET DISCOVERY
========================================================================]]

--- Register a secret for completion tracking
-- @param secret_id Secret identifier
-- @param config Optional secret configuration
function M.register_secret(secret_id, config)
    if not secret_id then
        return
    end

    registered_secrets[secret_id] = config or true
    print(string.format("[COLLECTIBLE_MANAGER] Registered secret: %s", secret_id))
end

--- Discover a secret
-- @param secret_id Secret identifier
function M.discover_secret(secret_id)
    if not secret_id then
        return
    end

    -- Auto-register if not already registered
    if not registered_secrets[secret_id] then
        M.register_secret(secret_id)
    end

    if discovered_secrets[secret_id] then
        return  -- Already discovered
    end

    discovered_secrets[secret_id] = true

    print(string.format("[COLLECTIBLE_MANAGER] Secret discovered: %s", secret_id))

    -- Save to persistence
    if config.use_flags then
        local success, Flags = pcall(require, "mvtk.core.flags")
        if success then
            Flags.set("secret_" .. secret_id, true)
        end
    end

    -- Show notification
    M.show_notification("Secret Discovered!", 3.0)

    -- Could trigger additional effects (minimap update, etc.)
end

--- Check if secret is discovered
-- @param secret_id Secret identifier
-- @return true if discovered
function M.is_secret_discovered(secret_id)
    return discovered_secrets[secret_id] == true
end

--[[========================================================================
    UTILITY
========================================================================]]

--- Clear all runtime data (for cleanup between room loads)
function M.clear_all()
    active_collectibles = {}
    room_collectibles = {}
    print("[COLLECTIBLE_MANAGER] Cleared all runtime data")
end

--- Full reset — clears all state including collected/discovered persistence.
-- Call this when deleting or switching save slots so no collected items
-- carry over into the new game session.
function M.reset()
    active_collectibles = {}
    collected_items = {}
    discovered_secrets = {}
    room_collectibles = {}
    registered_secrets = {}
    pending_spawns = {}
    completion_data = { per_room = {}, per_area = {} }
    print("[COLLECTIBLE_MANAGER] Reset all data")
end

--- Get all collectibles (for debugging)
-- @return Table of all active collectibles
function M.get_all_collectibles()
    return active_collectibles
end

--- Print debug info
function M.print_debug()
    print("=== COLLECTIBLE MANAGER DEBUG ===")
    print(string.format("Active collectibles: %d", table.maxn(active_collectibles)))
    print(string.format("Collected items: %d", table.maxn(collected_items)))
    print(string.format("Discovered secrets: %d", table.maxn(discovered_secrets)))
    print(string.format("Rooms tracked: %d", table.maxn(room_collectibles)))

    local global = M.get_global_completion()
    print(string.format("Global completion: %.1f%% (%d / %d)",
        global.percentage, global.collected, global.total_collectibles))
    print("=================================")
end

return M
