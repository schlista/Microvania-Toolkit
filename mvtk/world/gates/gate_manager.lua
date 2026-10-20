-- mvtk/world/gates/gate_manager.lua
-- Central gate system manager for ability-gated progression
-- Part of MV Toolkit - enables developers to easily create gated Metroidvania worlds

local Flags = require "mvtk.core.flags"
local C = require "mvtk.core.constants"
local Util = require "mvtk.core.util"
local KeyIds = require "mvtk.core.key_ids"
local Requirements = require "mvtk.world.gates.requirements"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })
-- Required runtime dependency: a dynamic optional load can run before Defold
-- loads this module and permanently replace the live resource with zero energy.
local EnergyState = require "mvtk.player.energy_state"

local M = {}

-- Active gates registry
local active_gates = {}
local known_gates = {} -- Map metadata survives streaming; it contains no live URLs.
local gate_configs = {}
local gate_types = {}
local gate_type_hash_to_string = {}  -- hash -> string key reverse lookup
local gate_revision = 0
local initialized = false

local PERSISTENT_UNLOCK_TYPES = {
    ability_requirement = true,
    action_barrier = true,
    item_requirement = true,
    destructible = true,
    sequence = true,
    height_barrier = true,
}

local gate_log = Util.make_debug_log("[GATE_MGR]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.gates)
end)

local function bump_revision()
    gate_revision = gate_revision + 1
end

local function serializable(value)
    if type(value) == "table" then
        local result = {}
        for key, item in pairs(value) do
            if type(key) == "string" or type(key) == "number" then result[key] = serializable(item) end
        end
        return result
    elseif type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
        return value
    end
end

local function remember_gate(id, config)
    if not config then return end
    local saved = serializable(config)
    if config.position then saved.position = { x = config.position.x, y = config.position.y } end
    known_gates[id] = { id = id, config = saved }
    bump_revision()
end

local function target_exists(target)
    if type(target) ~= "string" or target == "" then
        return false
    end
    local ok_url, target_url = pcall(msg.url, target)
    if not ok_url or not target_url then
        return false
    end
    local ok_exists, exists = pcall(go.exists, target_url)
    return ok_exists and exists or false
end

local function safe_post_target(target, message_id, data)
    if not target_exists(target) then
        return false
    end
    pcall(msg.post, target, message_id, data or {})
    return true
end

local function post_minimap(message_id, data)
    safe_post_target("main:/minimap_gui#minimap", hash(message_id), data or {})
end

local function post_game_manager(message_id, data)
    local payload = data or {}
    if safe_post_target("main:/game_manager#game_manager", hash(message_id), payload) then
        return
    end
    safe_post_target("/game_manager#game_manager", hash(message_id), payload)
end

-----------------------------------------------------------
-- Forward-declared helper functions (must be before callers)
-----------------------------------------------------------

local count_keys = Util.count_keys

local function normalize_hash_string(value)
    return Util.normalize_hash_string(value)
end

local function normalize_gate_type_id(type_id)
    return normalize_hash_string(type_id)
end

local function normalize_item_id(item_id)
    local key = KeyIds.canonicalize(item_id)
    if key == nil then
        key = normalize_hash_string(item_id)
    end
    if not key or key == "" then
        return nil
    end
    return key
end

M.normalize_item_id = normalize_item_id

local function boolish(value, default)
    if value == nil then
        return default and true or false
    end
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    local s = tostring(value):lower()
    if s == "true" or s == "1" or s == "yes" or s == "on" then
        return true
    end
    if s == "false" or s == "0" or s == "no" or s == "off" then
        return false
    end
    return default and true or false
end

local function default_persist_unlock(gate_kind)
    return PERSISTENT_UNLOCK_TYPES[gate_kind] == true
end

local function generate_gate_id(config)
    local room = config.room_id or "unknown"
    local pos = config.position or {x = 0, y = 0}
    return string.format("gate_%s_%d_%d", room, math.floor(pos.x), math.floor(pos.y))
end

local function merge_gate_config(gate_type_def, gate_config)
    local merged = {}

    -- Copy type defaults
    for k, v in pairs(gate_type_def) do
        if type(v) == "table" then
            merged[k] = {}
            for kk, vv in pairs(v) do
                merged[k][kk] = vv
            end
        else
            merged[k] = v
        end
    end

    -- Override with instance config
    for k, v in pairs(gate_config) do
        if type(v) == "table" and merged[k] and type(merged[k]) == "table" then
            -- Merge table properties
            for kk, vv in pairs(v) do
                merged[k][kk] = vv
            end
        else
            merged[k] = v
        end
    end

    return merged
end

local function check_ability_requirement(config)
    if not config.required_ability then return true end

    local ok, AbilityManager = pcall(require, "mvtk.abilities.ability_manager")
    if not ok then return false end

    local ability_id = normalize_hash_string(config.required_ability)
    if not ability_id or ability_id == "" then
        return true
    end

    return Requirements.evaluate({abilities={[ability_id]=true}}, {
        has_ability=function(id) return AbilityManager.has_ability and AbilityManager.has_ability(id) or false end,
    })
end

local function check_item_requirement(config)
    if not config.required_item then return true end

    local ok, Inventory = pcall(require, "mvtk.core.inventory")
    if not ok then return false end

    local item_id = normalize_item_id(config.required_item)
    if not item_id or item_id == "" then
        return true
    end

    return Requirements.evaluate({items={[item_id]=1}}, {
        has_item=function(id) return Inventory.has_item and Inventory.has_item(id) or false end,
    })
end

local function check_resource_requirement(config)
    if not config.required_resource or not config.resource_amount then return true end

    local ok, Inventory = pcall(require, "mvtk.core.inventory")
    if not ok then return false end

    local amount = 0
    if config.required_resource == "currency" then
        amount = Inventory.get_currency and Inventory.get_currency() or 0
    elseif config.required_resource == "energy" then
        local current, _ = EnergyState.get()
        amount = current or 0
    end

    return Requirements.evaluate({resources={[config.required_resource]=config.resource_amount}},
        {resources={[config.required_resource]=amount}})
end

local function check_timed_gate(gate)
    if not gate or not gate.config then return false end

    local config = gate.config
    local duration = config.timer_duration or 60  -- Default 60 seconds

    -- Initialize timer if not started
    if not gate.timer_start_time then
        gate.timer_start_time = os.time()
        Flags.set("gate_timer_" .. gate.id, gate.timer_start_time)
        gate_log(string.format("Timed gate %s started: %d second countdown", gate.id, duration))
        return false
    end

    -- Check if time has elapsed
    local elapsed = os.time() - gate.timer_start_time
    if elapsed >= duration then
        gate_log(string.format("Timed gate %s: timer expired (%d seconds)", gate.id, elapsed))
        return true
    end

    return false
end

local function check_sequence_gate(gate)
    if not gate or not gate.config then return false end

    local config = gate.config
    local required_sequence = config.required_sequence or {}

    if #required_sequence == 0 then
        gate_log(string.format("WARNING: Sequence gate %s has no required_sequence", gate.id))
        return true  -- No sequence required, pass by default
    end

    -- Get current sequence progress from flags
    local sequence_key = "gate_seq_" .. gate.id
    local current_progress = Flags.get(sequence_key) or 0

    -- Check if sequence is complete
    if current_progress >= #required_sequence then
        gate_log(string.format("Sequence gate %s: complete (%d/%d)", gate.id, current_progress, #required_sequence))
        return true
    end

    return false
end

-----------------------------------------------------------
-- Initialization
-----------------------------------------------------------

function M.init()
    if initialized then
        return
    end
    gate_log("Initializing gate system...")

    gate_types = Util.require_config("developer.config.gate_types")
    gate_type_hash_to_string = {}
    for key, _ in pairs(gate_types) do
        gate_type_hash_to_string[hash(key)] = key
    end
    gate_log(string.format("Loaded %d gate type definitions", count_keys(gate_types)))

    gate_configs = Util.require_config("developer.config.gates")
    gate_log(string.format("Loaded %d gate configurations", #gate_configs))

    active_gates = {}
    bump_revision()
    initialized = true
end

--- Normalize gate ID to string key
-- Accepts hash or string, returns stable string key
local function normalize_gate_id(gate_id)
    local key = normalize_hash_string(gate_id)
    return key or ""
end

local function ensure_initialized()
    if not initialized then
        M.init()
    end
end

function M.normalize_gate_id(gate_id)
    return normalize_gate_id(gate_id)
end

-----------------------------------------------------------
-- Gate Type Management
-----------------------------------------------------------

function M.get_gate_type(type_id)
    ensure_initialized()
    local key = normalize_gate_type_id(type_id)
    if not key then
        return nil
    end
    return gate_types[key]
end

--- Convert a gate type hash to its string key
-- @param type_hash Hash of the gate type
-- @return string key or nil
function M.gate_type_hash_to_key(type_hash)
    ensure_initialized()
    return gate_type_hash_to_string[type_hash]
end

function M.register_gate_type(type_id, definition)
    ensure_initialized()
    if not type_id or type(definition) ~= "table" then
        gate_log("ERROR: Invalid gate type registration")
        return false
    end

    local key = normalize_gate_type_id(type_id)
    if not key then
        gate_log("ERROR: Invalid gate type id")
        return false
    end
    gate_types[key] = definition
    gate_type_hash_to_string[hash(key)] = key
    gate_log(string.format("Registered custom gate type: %s", key))
    return true
end

function M.get_all_gate_types()
    ensure_initialized()
    return gate_types
end

-----------------------------------------------------------
-- Gate Instance Management
-----------------------------------------------------------

function M.spawn_gate(gate_config)
    ensure_initialized()
    if not gate_config or not gate_config.gate_type then
        gate_log("ERROR: Invalid gate configuration")
        return nil
    end

    local gate_type_key = normalize_gate_type_id(gate_config.gate_type)
    local gate_type = M.get_gate_type(gate_type_key)
    if not gate_type then
        gate_log(string.format("ERROR: Unknown gate type: %s", tostring(gate_config.gate_type)))
        return nil
    end

    -- Generate gate ID if not provided
    local gate_id = normalize_gate_id(gate_config.id)
    if gate_id == "" then
        gate_id = normalize_gate_id(generate_gate_id(gate_config))
    end

    -- Merge configuration with type defaults
    local merged_config = merge_gate_config(gate_type, gate_config)
    merged_config.id = gate_id
    merged_config.gate_type = gate_type_key
    if merged_config.required_key and not merged_config.required_item then
        merged_config.required_item = merged_config.required_key
    end
    merged_config.required_key = nil
    merged_config.required_item = normalize_item_id(merged_config.required_item)
    merged_config.required_ability = normalize_hash_string(merged_config.required_ability)
    merged_config.required_action = normalize_hash_string(merged_config.required_action)
    if not merged_config.required_action then
        merged_config.required_action = merged_config.required_ability
    end

    -- Timed gate support accepts either top-level timer_duration or interaction.timer_duration
    if merged_config.type == "timed" and merged_config.timer_duration == nil and merged_config.interaction then
        merged_config.timer_duration = tonumber(merged_config.interaction.timer_duration) or nil
    end
    if merged_config.timer_duration ~= nil then
        merged_config.timer_duration = tonumber(merged_config.timer_duration) or 0
    end

    -- Persistence policy: hard gates persist by default, soft gates do not.
    if merged_config.persist_unlock == nil then
        if merged_config.stays_open ~= nil then
            merged_config.persist_unlock = boolish(merged_config.stays_open, true)
        else
            merged_config.persist_unlock = default_persist_unlock(merged_config.type)
        end
    else
        merged_config.persist_unlock = boolish(merged_config.persist_unlock, true)
    end

    -- Check persistent unlock after config merge so policy is honored
    remember_gate(gate_id, merged_config)
    if M.is_gate_unlocked(gate_id, merged_config) then
        gate_log(string.format("Gate %s already unlocked, skipping spawn", gate_id))
        return nil
    end

    -- Store active gate
    local gate_data = {
        id = gate_id,
        config = merged_config,
        url = nil,  -- Will be set by gate script
        unlocked = false
    }

    -- Restore timed gate state from flags
    if merged_config.type == "timed" then
        local timer_key = "gate_timer_" .. gate_id
        local saved_start_time = Flags.get(timer_key)
        if saved_start_time then
            gate_data.timer_start_time = saved_start_time
            gate_log(string.format("Restored timed gate %s: started at %d", gate_id, saved_start_time))
        end
    end

    active_gates[gate_id] = gate_data

    gate_log(string.format("Spawned gate: %s (type: %s)", gate_id, gate_type_key))
    return merged_config
end

function M.register_gate_instance(gate_id, gate_url)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    if key == "" then
        gate_log("WARNING: register_gate_instance called with empty gate_id")
        return
    end
    if active_gates[key] then
        active_gates[key].url = gate_url
        gate_log(string.format("Registered gate instance: %s url=%s", key, tostring(gate_url)))
    else
        local config = nil
        for _, gate_config in ipairs(gate_configs) do
            if normalize_gate_id(gate_config and gate_config.id) == key then
                config = gate_config
                break
            end
        end
        -- Create a new entry if not pre-spawned via spawn_gate
        active_gates[key] = {
            id = key,
            url = gate_url,
            config = config,
            unlocked = false
        }
        gate_log(string.format("Registered new gate instance: %s url=%s", key, tostring(gate_url)))
    end
    remember_gate(key, active_gates[key].config)
end

function M.unregister_gate_instance(gate_id, gate_url)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key]
    if not gate then
        return
    end

    if gate_url and gate.url and gate.url ~= gate_url then
        gate_log(string.format(
            "Skipped unregister for gate %s due to url mismatch current=%s caller=%s",
            key,
            tostring(gate.url),
            tostring(gate_url)
        ))
        return
    end

    if gate then
        active_gates[key] = nil
        bump_revision()
        gate_log(string.format("Unregistered gate instance: %s url=%s", key, tostring(gate_url or gate.url)))
    end
end

-----------------------------------------------------------
-- Gate Requirements & Unlocking
-----------------------------------------------------------

function M.check_gate_requirements(gate_id)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key] or known_gates[key]
    if not gate then return false end
    if not gate.config then return false end

    local config = gate.config
    local gate_type = config.type

    if gate_type == "ability_requirement" then
        return check_ability_requirement(config)
    elseif gate_type == "action_barrier" then
        -- Action barriers unlock only when hit by their required action.
        return false
    elseif gate_type == "item_requirement" then
        return check_item_requirement(config)
    elseif gate_type == "resource_requirement" then
        return check_resource_requirement(config)
    elseif gate_type == "destructible" then
        return check_ability_requirement(config)  -- Destructibles need ability too
    elseif gate_type == "hazard_barrier" then
        return check_ability_requirement(config)
    elseif gate_type == "height_barrier" then
        return check_ability_requirement(config)
    elseif gate_type == "timed" then
        return check_timed_gate(gate)
    elseif gate_type == "sequence" then
        return check_sequence_gate(gate)
    elseif gate_type == "one_way" then
        return false
    end

    return false
end

-- Sequence gate activation (called externally when player activates switches)
function M.activate_sequence_step(gate_id, step_id)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key]
    if not gate or not gate.config then
        gate_log(string.format("WARNING: Cannot activate sequence for unknown gate: %s", key))
        return false
    end

    local config = gate.config
    local required_sequence = config.required_sequence or {}

    if #required_sequence == 0 then
        return false
    end

    -- Get current progress
    local sequence_key = "gate_seq_" .. key
    local current_progress = Flags.get(sequence_key) or 0

    -- Check if already complete
    if current_progress >= #required_sequence then
        return true
    end

    -- Check if this is the correct next step
    local expected_step = required_sequence[current_progress + 1]

    if step_id == expected_step then
        -- Correct step!
        current_progress = current_progress + 1
        Flags.set(sequence_key, current_progress)
        gate_log(string.format("Sequence gate %s: step %d/%d activated (%s)", key, current_progress, #required_sequence, step_id))

        -- Check if sequence is now complete
        if current_progress >= #required_sequence then
            gate_log(string.format("Sequence gate %s: COMPLETE! Auto-unlocking...", key))
            M.unlock_gate(key, "sequence_complete")
            return true
        end

        bump_revision()
        post_minimap("refresh_gates", {})
        return true
    else
        -- Wrong step! Reset sequence
        gate_log(string.format("Sequence gate %s: WRONG STEP! Expected %s, got %s. Resetting...", key, tostring(expected_step), tostring(step_id)))
        Flags.set(sequence_key, 0)
        bump_revision()
        post_minimap("refresh_gates", {})

        -- Play error sound/feedback
        if config.on_sequence_fail then
            config.on_sequence_fail(gate_id, step_id, expected_step)
        end

        return false
    end
end

-- Reset sequence progress (for debugging or game logic)
function M.reset_sequence(gate_id)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key]
    if not gate then return false end

    local sequence_key = "gate_seq_" .. key
    Flags.set(sequence_key, 0)
    gate_log(string.format("Sequence gate %s: progress reset", key))
    bump_revision()
    return true
end

-- Get sequence progress (for UI display)
function M.get_sequence_progress(gate_id)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key]
    if not gate or not gate.config then return 0, 0 end

    local required_sequence = gate.config.required_sequence or {}
    local sequence_key = "gate_seq_" .. key
    local current_progress = Flags.get(sequence_key) or 0

    return current_progress, #required_sequence
end

-- Get timed gate remaining time (for UI countdown display)
function M.get_timer_remaining(gate_id)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key]
    if not gate or not gate.config or gate.config.type ~= "timed" then
        return 0
    end

    if not gate.timer_start_time then
        return gate.config.timer_duration or 60
    end

    local duration = gate.config.timer_duration or 60
    local elapsed = os.time() - gate.timer_start_time
    local remaining = math.max(0, duration - elapsed)

    return remaining
end

function M.unlock_gate(gate_id, source, opts)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key]
    if not gate then
        gate_log(string.format("WARNING: Attempted to unlock unknown gate: %s", key))
        return false
    end

    if gate.unlocked then
        return true  -- Already unlocked
    end

    opts = opts or {}
    local temporary = opts.temporary and true or false
    local persist_unlock = opts.persist_unlock
    if persist_unlock == nil then
        if gate.config and gate.config.persist_unlock ~= nil then
            persist_unlock = gate.config.persist_unlock and true or false
        else
            persist_unlock = true
        end
    else
        persist_unlock = boolish(persist_unlock, true)
    end
    if temporary then
        persist_unlock = false
    end

    -- Mark as unlocked
    gate.unlocked = true
    gate.temporary = temporary
    gate.persist_unlock = persist_unlock
    if persist_unlock then
        Flags.set("gate_" .. key, true)
    else
        Flags.clear("gate_" .. key)
    end
    bump_revision()

    gate_log(string.format(
        "Gate unlocked: %s (source=%s type=%s temporary=%s persist_unlock=%s flag=%s url=%s)",
        key,
        tostring(source or "unknown"),
        tostring(gate.config and gate.config.type or "nil"),
        tostring(temporary),
        tostring(persist_unlock),
        tostring(Flags.get("gate_" .. key, nil)),
        tostring(gate.url)
    ))

    -- Notify gate instance
    local payload = { gate_id = key, source = source, temporary = temporary, persist_unlock = persist_unlock }
    if gate.url and go.exists(gate.url) then
        pcall(msg.post, gate.url, hash("gate_unlocked"), payload)
    end

    -- Notify minimap
    post_minimap("gate_unlocked", payload)

    -- Global event for other systems
    post_game_manager("gate_unlocked", payload)

    return true
end

function M.is_gate_unlocked(gate_id, gate_config)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local config = gate_config
    if not config then
        local gate_entry = active_gates[key]
        config = gate_entry and gate_entry.config or nil
    end

    local allows_persistent = true
    if config and config.persist_unlock ~= nil then
        allows_persistent = config.persist_unlock and true or false
    end

    -- Check flags first (persistent-only gates)
    if allows_persistent and Flags.has("gate_" .. key) then
        return true
    end

    -- Check active gates
    local gate = active_gates[key]
    return gate and gate.unlocked or false
end

function M.lock_gate(gate_id, reason)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key]
    if not gate or not gate.unlocked then
        return false
    end

    local was_temporary = gate.temporary and true or false
    local was_persistent = gate.persist_unlock and true or false
    gate.unlocked = false
    gate.temporary = nil
    gate.persist_unlock = nil
    Flags.clear("gate_" .. key)
    bump_revision()

    gate_log(string.format("Gate locked: %s (reason: %s)", key, tostring(reason or "unknown")))

    local payload = { gate_id = key, reason = reason, temporary = was_temporary, persist_unlock = was_persistent }

    if gate.url and go.exists(gate.url) then
        pcall(msg.post, gate.url, hash("gate_locked"), payload)
    end

    post_minimap("gate_locked", payload)
    post_game_manager("gate_locked", payload)

    return true
end

-----------------------------------------------------------
-- Room Integration
-----------------------------------------------------------

function M.load_gates_for_room(room_id)
    ensure_initialized()
    if not room_id then return {} end

    local room_gates = {}

    -- Find all gates for this room
    for _, gate_config in ipairs(gate_configs) do
        if gate_config.room_id == room_id then
            local spawned = M.spawn_gate(gate_config)
            if spawned then
                table.insert(room_gates, spawned)
            end
        end
    end

    gate_log(string.format("Loaded %d gates for room: %s", #room_gates, room_id))
    return room_gates
end

function M.unload_gates_for_room(room_id)
    ensure_initialized()
    local count = 0
    local to_remove = {}
    for gate_id, gate in pairs(active_gates) do
        if gate.config and gate.config.room_id == room_id then
            to_remove[#to_remove + 1] = gate_id
        end
    end
    for _, gate_id in ipairs(to_remove) do
        M.unregister_gate_instance(gate_id)
        count = count + 1
    end
    gate_log(string.format("Unloaded %d gates from room: %s", count, room_id))
end

function M.despawn_gate(gate_id)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    if key == "" then
        return false
    end
    if active_gates[key] then
        active_gates[key] = nil
        bump_revision()
        gate_log(string.format("Despawned gate: %s", key))
        return true
    end
    return false
end

-----------------------------------------------------------
-- Query Functions
-----------------------------------------------------------

function M.get_gate_config(gate_id)
    ensure_initialized()
    local key = normalize_gate_id(gate_id)
    local gate = active_gates[key]
    return gate and gate.config or nil
end

function M.get_all_gates()
    ensure_initialized()
    return active_gates
end

function M.get_map_gates()
    ensure_initialized()
    for id, metadata in pairs(known_gates) do
        local live = active_gates[id]
        metadata.unlocked = (live and live.unlocked) or M.is_gate_unlocked(id, metadata.config)
        metadata.temporary = live and live.temporary or false
    end
    return known_gates
end

function M.get_gate_revision()
    ensure_initialized()
    return gate_revision
end

function M.get_gates_by_type(gate_type)
    ensure_initialized()
    local gate_type_key = normalize_gate_type_id(gate_type)
    local result = {}
    for _, gate in pairs(active_gates) do
        if gate.config and gate.config.gate_type == gate_type_key then
            table.insert(result, gate)
        end
    end
    return result
end

function M.get_locked_gates()
    ensure_initialized()
    local result = {}
    for gate_id, gate in pairs(active_gates) do
        if not gate.unlocked then
            table.insert(result, gate)
        end
    end
    return result
end

function M.get_accessible_gates()
    ensure_initialized()
    local result = {}
    for gate_id, gate in pairs(active_gates) do
        if not gate.unlocked and M.check_gate_requirements(gate_id) then
            table.insert(result, gate)
        end
    end
    return result
end

-----------------------------------------------------------
-- Debug Functions
-----------------------------------------------------------

function M.unlock_all_gates()
    ensure_initialized()
    local count = 0
    for gate_id, gate in pairs(active_gates) do
        if not gate.unlocked then
            M.unlock_gate(gate_id, "debug_unlock_all")
            count = count + 1
        end
    end
    gate_log(string.format("DEBUG: Unlocked all gates (%d)", count))
end

function M.reset_all_gates()
    ensure_initialized()
    for gate_id in pairs(active_gates) do
        Flags.clear("gate_" .. gate_id)
    end
    active_gates = {}
    known_gates = {}
    bump_revision()
    gate_log("DEBUG: Reset all gates")
end

function M.print_gate_status()
    ensure_initialized()
    gate_log("=== Gate Status Report ===")
    gate_log(string.format("Total gates: %d", count_keys(active_gates)))

    local locked = 0
    local unlocked = 0
    local accessible = 0

    for gate_id, gate in pairs(active_gates) do
        if gate.unlocked then
            unlocked = unlocked + 1
        else
            locked = locked + 1
            if M.check_gate_requirements(gate_id) then
                accessible = accessible + 1
            end
        end
    end

    gate_log(string.format("Locked: %d | Unlocked: %d | Accessible: %d", locked, unlocked, accessible))
end

Util.register_checkpoint_provider("map_gates", {
    capture = function() return known_gates end,
    apply = function(data)
        known_gates = serializable(data) or {}
        bump_revision()
    end,
    defaults = function() known_gates = {}; bump_revision() end,
    version = 1,
    order = 35,
    description = "Authored gate metadata for backtracking through unloaded rooms",
})

return M
