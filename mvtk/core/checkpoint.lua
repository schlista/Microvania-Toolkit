-- mvtk/core/checkpoint.lua
-- ============================================================================
-- Checkpoint and Save System
-- ============================================================================
-- Manages save/load functionality with extensible provider system.
-- Handles player checkpoints, game state persistence, and module data.
--
-- Features:
--   - Multiple save slots
--   - Provider registration for extensible save data
--   - Auto-save and manual save
--   - Death penalties and respawn
--   - Version tracking and migration
--
-- Save Data Structure:
--   - checkpoint: Player respawn position
--   - health: Player health state
--   - explored: Minimap explored areas
--   - inventory: Items and currency
--   - flags: Game state flags
--   - doors: Opened door states
--   - abilities: Unlocked abilities
--   - modules: Provider-specific data
--   - meta: Version, playtime, last saved time
--
-- Provider System:
--   External modules can register to save/load their own data.
--   Providers define capture() and apply() functions.
--
-- Usage:
--   Checkpoint.set_slot(1)
--   Checkpoint.save("manual_save")
--   Checkpoint.load(1)
--   Checkpoint.set_checkpoint(player_position)

local C = require "mvtk.core.constants"
local Util = require "mvtk.core.util"
local SafeRequire = require "mvtk.core.safe_require"
local SavePaths = require "mvtk.core.save_paths"
local Migrations = require "mvtk.core.save_migrations"
local MigrationConfig = require "developer.config.save_migrations"
local Discovery = require "mvtk.map.discovery"

local M = {}
local blocked_slots = {}
local function saved_hash(text) return hash_to_hex(hash(text)) end

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.gameplay and _Dbg.gameplay.checkpoint then
        _orig_print(...)
    end
end

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

M.VERSION = 2  -- Save format version (increment when structure changes)
local SAVE_PREFIX = "mvtk_save_slot_"  -- Prefix for save file keys
M.slot = 1  -- Current active save slot (1-based)

local deep_copy = Util.deep_copy

-- Retired checkpoint providers: accept old saves, omit these modules from new
-- snapshots. Bank, achievements and upgrades registered stock providers;
-- leveling and quests cover the legacy payload cases in the compatibility plan.
-- Unrelated providers remain available for registration later in the session.
local RETIRED_PROVIDERS = {
    bank = true,
    achievements = true,
    leveling = true,
    quests = true,
    upgrades = true,
}

local function drop_retired_provider_data(data)
    for id in pairs(RETIRED_PROVIDERS) do
        data.modules[id] = nil
        if data.meta.providers then data.meta.providers[id] = nil end
        data[id] = nil
    end
end

-- ============================================================================
-- SAVE DATA STRUCTURE
-- ============================================================================

-- Create a new save data structure with default values
-- Returns: Table with all save data fields initialized
local function new_data()
    return {
        checkpoint = nil,  -- Last checkpoint position {x, y}
        health = nil,  -- Player health value
        explored = {},  -- Explored minimap tiles
        minimap_view_center = nil,  -- Minimap camera position
        inventory = { items = {}, currency = 0 },  -- Player inventory
        flags = {},  -- Game state flags (story progress, etc.)
        doors = {},  -- Opened door IDs
        abilities = {},  -- Unlocked abilities
        meta = { version = M.VERSION, playtime_s = 0, last_saved = 0 },  -- Metadata
        modules = {},  -- Provider-specific save data
    }
end

-- Current active save data (starts with defaults)
M.data = new_data()
local save_batch_depth = 0

-- Group synchronous progression changes into one durable snapshot. Nested
-- autosaves are requests; the outer caller receives the actual disk result.
function M.batch(reason, callback)
    save_batch_depth = save_batch_depth + 1
    local ok, result = pcall(callback)
    save_batch_depth = save_batch_depth - 1
    if not ok then return false, result end
    if save_batch_depth > 0 then return true end
    return M.save({ reason = reason })
end

-- ============================================================================
-- PROVIDER SYSTEM
-- ============================================================================

-- Registered save/load providers (modules that want to persist data)
local PROVIDERS = {}

-- Cached sorted provider list (invalidated when providers change)
local PROVIDER_CACHE = nil

-- Invalidate the provider cache (forces re-sort on next access)
local function invalidate_provider_cache()
    PROVIDER_CACHE = nil
end

-- Get sorted list of providers (sorted by order, then by id)
-- Returns: Cached sorted provider list
--
-- Providers are sorted by their 'order' field (lower = earlier in save/load)
-- to ensure dependencies are handled correctly.
local function sorted_providers()
    if PROVIDER_CACHE then return PROVIDER_CACHE end

    local list = {}
    for id, entry in pairs(PROVIDERS) do
        list[#list + 1] = entry
    end

    -- Sort by order (ascending), then by id (alphabetically)
    table.sort(list, function(a, b)
        if a.order == b.order then
            return a.id < b.id
        end
        return a.order < b.order
    end)

    PROVIDER_CACHE = list
    return list
end

-- ============================================================================
-- PROVIDER REGISTRATION
-- ============================================================================

-- Register a save/load provider
-- id: Unique string identifier for this provider
-- opts: Provider configuration table:
--   capture: function(context) - Returns data to save (optional)
--   apply: function(data, context) - Loads data (optional)
--   defaults: function(context) - Sets defaults when no data (optional)
--   version: Number - Provider data version (default: 1)
--   order: Number - Sort order for save/load (default: 100, lower = earlier)
--   mirror_key: String - Key in M.data to mirror this data (optional)
--   description: String - Human-readable description (optional)
--
-- Example:
--   Checkpoint.register_provider("my_module", {
--     capture = function() return {my_value = 123} end,
--     apply = function(data) my_module.load(data) end,
--     version = 1,
--     order = 50
--   })
function M.register_provider(id, opts)
    if type(id) ~= "string" or id == "" then
        error("checkpoint.register_provider: id must be a non-empty string", 2)
    end
    opts = opts or {}
    local record = {
        id = id,
        capture = opts.capture,
        apply = opts.apply,
        defaults = opts.defaults,
        version = opts.version or 1,
        migrations = opts.migrations,
        order = opts.order or 100,
        mirror_key = opts.mirror_key,
        description = opts.description,
    }
    if not record.capture and not record.apply then
        error("checkpoint.register_provider: provider '" .. id .. "' must define capture and/or apply", 2)
    end
    PROVIDERS[id] = record
    invalidate_provider_cache()
    return true
end

function M.unregister_provider(id)
    if PROVIDERS[id] then
        PROVIDERS[id] = nil
        invalidate_provider_cache()
        return true
    end
    return false
end

local function ensure_defaults(data)
    data = data or {}
    local defaults = new_data()
    for k, v in pairs(defaults) do
        if data[k] == nil then
            data[k] = deep_copy(v)
        end
    end
    data.meta = data.meta or {}
    data.meta.version = data.meta.version or M.VERSION
    data.modules = data.modules or {}
    return data
end

local function copy_for_storage(value)
    if type(value) == "table" then
        return deep_copy(value)
    end
    return value
end

local function apply_providers(modules, context)
    modules = modules or {}
    local sorted = sorted_providers()
    print(string.format("[CHECKPOINT] apply_providers called with %d providers, context: %s", #sorted, context.reason or "?"))
    for _, provider in ipairs(sorted) do
        local payload = modules[provider.id]
        if provider.mirror_key then
            if payload and payload.data ~= nil then
                M.data[provider.mirror_key] = copy_for_storage(payload.data)
            else
                M.data[provider.mirror_key] = M.data[provider.mirror_key] or {}
            end
        end
        local apply_ctx = {
            slot = context.slot,
            reason = context.reason,
            source = context.source,
            stored_version = payload and payload.version or nil,
            provider_version = provider.version,
        }
        if payload and payload.data ~= nil and provider.apply then
            local data = payload.data
            if type(data) == "table" then
                data = deep_copy(data)
            end
            print(string.format("[CHECKPOINT] Calling apply() for provider '%s'", provider.id))
            local ok, err = pcall(provider.apply, data, apply_ctx)
            if not ok then
                print(string.format("[CHECKPOINT] Provider '%s' apply failed: %s", provider.id, tostring(err)))
                if provider.defaults then
                    pcall(provider.defaults, apply_ctx)
                end
            end
        elseif provider.defaults then
            print(string.format("[CHECKPOINT] Calling defaults() for provider '%s' (no payload)", provider.id))
            pcall(provider.defaults, apply_ctx)
        end
    end
end

-- Reset all in-memory state to defaults by calling every registered provider's
-- defaults() function. Use this when deleting a save slot so no data bleeds
-- into a new game started in the same session.
-- slot: The slot number being cleared (passed to provider context).
function M.reset_to_defaults(slot)
    M.resume_saves()
    M.data = new_data()
    apply_providers({}, { reason = "delete", slot = slot or M.slot })
end

local function capture_providers(context)
    -- Providers registered later must not lose their saved payloads.
    local modules = deep_copy(M.data.modules or {})
    local provider_meta = {}
    local sorted = sorted_providers()
    for _, provider in ipairs(sorted) do
        if provider.capture then
            local ok, data = pcall(provider.capture, context)
            if not ok then
                print(string.format("[CHECKPOINT] Provider '%s' capture failed: %s", provider.id, tostring(data)))
            elseif data ~= nil then
                modules[provider.id] = {
                    version = provider.version,
                    data = copy_for_storage(data),
                }
                provider_meta[provider.id] = {
                    version = provider.version,
                    captured = context.timestamp,
                }
                if provider.mirror_key then
                    M.data[provider.mirror_key] = copy_for_storage(data)
                end
            elseif provider.defaults then
                pcall(provider.defaults, context)
            end
        end
    end
    return modules, provider_meta
end

-- ============================================================================
-- CHECKPOINT MANAGEMENT
-- ============================================================================

-- Set the player's respawn checkpoint
-- pos: Position vector or table with .x and .y fields
-- room_id: Optional room identifier where checkpoint is located
--
-- Updates the checkpoint position and triggers an autosave.
-- Call this when player touches a save point or checkpoint trigger.
function M.set_checkpoint(pos, room_id)
    if not pos then return end
    M.data = ensure_defaults(M.data)
    M.data.checkpoint = { x = pos.x, y = pos.y, room_id = room_id }
    
    -- If room_id not provided, try to get it from RoomManager
    if not room_id then
        local ok_rm, RoomManager = SafeRequire("mvtk.map.streaming.room_manager", "mvtk.core.checkpoint")
        if ok_rm and RoomManager and RoomManager.get_current_room then
            local current = RoomManager.get_current_room()
            if current then
                M.data.checkpoint.room_id = current
            end
        end
    end

    -- Auto-save after setting checkpoint
    pcall(M.autosave, "checkpoint")
end

function M.capture_from_runtime()
    M.data = ensure_defaults(M.data)
    local mini = rawget(_G, "MINIMAP_MODULE")
    if mini and mini.snapshot then
        local snap = mini.snapshot()
        M.data.explored = deep_copy(snap.explored or M.data.explored)
        if snap.view_center then
            M.data.minimap_view_center = deep_copy(snap.view_center)
        end
    end
    return M.data
end

local SESSION_START = os.time and os.time() or 0

function M.key_for(slot)
    local name = SAVE_PREFIX .. tostring(slot or M.slot or 1)
    return SavePaths.path(name)
end

local LAST_SLOT_NAME = "mvtk_last_slot"

function M.last_slot_key()
    return SavePaths.path(LAST_SLOT_NAME)
end

local function is_saved_payload(data)
    if type(data) ~= "table" then
        return false
    end
    if data.__deleted == true then
        return false
    end
    if next(data) == nil then
        return false
    end
    if data.meta ~= nil then
        return true
    end
    return (data.checkpoint ~= nil)
        or (data.modules ~= nil)
        or (data.flags ~= nil)
        or (data.inventory ~= nil)
        or (data.explored ~= nil)
end

-- Read compatibility only: older checksums used debug hash names, which can
-- change between sessions. New writes use save_checksum's stable identities.
local function compute_legacy_checksum(data)
    local buffer = {}
    local function visit(value, path)
        local t = type(value)
        if t == "table" then
            buffer[#buffer + 1] = "{"
            local keys = {}
            for k, _ in pairs(value) do
                if not (path[#path] == "meta" and k == "checksum") then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                buffer[#buffer + 1] = tostring(k)
                path[#path + 1] = k
                visit(value[k], path)
                path[#path] = nil
            end
            buffer[#buffer + 1] = "}"
        elseif t == "number" then
            buffer[#buffer + 1] = string.format("%.17g", value)
        elseif t == "boolean" then
            buffer[#buffer + 1] = value and "true" or "false"
        elseif t == "string" then
            buffer[#buffer + 1] = value
        else
            buffer[#buffer + 1] = t
        end
    end
    visit(data, {})
    return tostring(hash(table.concat(buffer, "|")))
end
local compute_checksum = require("mvtk.core.save_checksum").compute
M.compute_checksum = compute_checksum

local function validate_checksum(data, label)
    if type(data) ~= "table" then return false end
    if data.meta ~= nil and type(data.meta) ~= "table" then return false end
    local stored = data.meta and data.meta.checksum
    if not stored then
        return true -- Older saves without a checksum are treated as valid.
    end
    local expected = type(stored) == "string" and stored:sub(1,3) == "v2:"
        and compute_checksum(data) or compute_legacy_checksum(data)
    if tostring(stored) ~= tostring(expected) then
        print(string.format("[CHECKPOINT] Checksum mismatch for %s", tostring(label or "save")))
        return false
    end
    return true
end

-- One read-only validation path for Continue, slot metadata, and migration.
function M.validate_saved(data)
    if not is_saved_payload(data) then return false, "missing" end
    local ok, valid = pcall(validate_checksum, data)
    if not ok or not valid then return false, "corrupt" end
    if MigrationConfig.version ~= 1 then return false, "unsupported_migration_config" end
    return Migrations.check(data, PROVIDERS, SavePaths.game_id())
end

function M.inspect_slot(slot)
    local key = M.key_for(slot)
    local ok, data = pcall(sys.load, key)
    local valid, reason = false, "corrupt"
    if ok then valid, reason = M.validate_saved(data) end
    if valid then return data, nil, "primary" end
    -- A newer/foreign payload is not corruption; do not replace it with a backup.
    if reason ~= "missing" and reason ~= "corrupt" then return nil, reason end
    local backup_ok, backup = pcall(sys.load, key .. "_backup")
    local backup_valid, backup_reason = false, "corrupt"
    if backup_ok then backup_valid, backup_reason = M.validate_saved(backup) end
    if backup_valid then return backup, nil, "backup" end
    if backup_reason ~= "missing" then return nil, backup_reason end
    return nil, reason
end

local function preserve_upgrade_backup(key, data)
    local backup_key = key .. "_pre_upgrade"
    local ok, saved = pcall(sys.load, backup_key)
    if not ok then return false, "Cannot read pre-upgrade backup" end
    if type(saved) == "table" and next(saved) ~= nil then
        return M.validate_saved(saved)
    end
    local written, result = pcall(sys.save, backup_key, data)
    if not written or result == false then return false, "Cannot preserve pre-upgrade backup" end
    local checked, copy = pcall(sys.load, backup_key)
    if not checked or compute_checksum(copy) ~= compute_checksum(data) then return false, "Pre-upgrade backup verification failed" end
    return true
end

function M.set_slot(slot)
    local s = tonumber(slot) or 1
    M.slot = math.max(1, math.floor(s))
    if save_batch_depth == 0 then
        pcall(sys.save, M.last_slot_key(), { slot = M.slot })
    end
end

-- ============================================================================
-- SAVE/LOAD SYSTEM
-- ============================================================================

-- Save game to a slot
-- slot_or_opts: Slot number (1-3) OR options table
-- maybe_opts: Options table if slot was provided as first argument
--
-- Options table fields:
--   slot: Slot number to save to (overrides first argument)
--   reason: String describing why save occurred (for debugging/UI)
--
-- Returns: true if save successful, false otherwise
--
-- Examples:
--   Checkpoint.save(1)  -- Save to slot 1
--   Checkpoint.save({slot = 2, reason = "manual_save"})
--   Checkpoint.save(1, {reason = "checkpoint_activated"})
-- A death awaiting checkpoint restoration must not capture unsaved gameplay.
-- The exit callback completes the same narrow transaction used by Restart.
local save_suspension
function M.suspend_saves(reason, on_exit)
    save_suspension = { reason = reason, on_exit = on_exit }
end
function M.resume_saves(reason)
    if not reason or (save_suspension and save_suspension.reason == reason) then
        save_suspension = nil
    end
end
function M.is_save_suspended() return save_suspension ~= nil end
function M.flush_suspended_save()
    if not save_suspension then return true end
    if not save_suspension.on_exit then return false, save_suspension.reason end
    local ok, saved, err = pcall(save_suspension.on_exit)
    if not ok then return false, tostring(saved) end
    return saved == true, err
end

local function can_write_slot(slot)
    local _, blocked = M.inspect_slot(slot)
    if blocked == "missing" then blocked_slots[slot] = nil end
    if blocked_slots[slot] then return false, blocked_slots[slot] end
    if blocked and blocked ~= "missing" and blocked ~= "corrupt" then
        M.last_error = blocked
        return false, blocked
    end
    return true
end

-- A host can finish writing and still report failure. Verify the actual payload
-- before retrying, otherwise a durable death fee could be charged twice.
local function snapshot_committed(key, intended)
    local ok, saved = pcall(sys.load, key)
    return ok and is_saved_payload(saved) and validate_checksum(saved)
        and compute_checksum(saved) == compute_checksum(intended)
end

-- Shared integrity/backup boundary. sys.save succeeds without a return value.
local function write_snapshot(slot, data, inspected)
    if not inspected then
        local writable, reason = can_write_slot(slot)
        if not writable then return false, reason end
    end
    local key = M.key_for(slot)
    local existing
    if inspected then
        if inspected.source == "primary" then existing = inspected.existing end
    else
        local existing_ok, loaded = pcall(sys.load, key)
        if existing_ok and is_saved_payload(loaded) and validate_checksum(loaded) then
            existing = loaded
        end
    end
    if existing then
        local backed_up, result = pcall(sys.save, key .. "_backup", existing)
        if (not backed_up or result == false) and not snapshot_committed(key .. "_backup", existing) then
            return false, "Cannot preserve save backup"
        end
    end
    data.meta.checksum = compute_checksum(data)
    local ok, err = pcall(sys.save, key, data)
    if (not ok or err == false) and not snapshot_committed(key, data) then
        print(string.format("[CHECKPOINT] Failed to save slot %s: %s", key, tostring(err)))
        return false, tostring(err)
    end
    pcall(sys.save, M.last_slot_key(), { slot = slot })
    return true
end

-- Update named providers in the loaded snapshot without capturing any runtime
-- provider, checkpoint position, discovery, items, flags or other unsaved gains.
-- Used by death recovery to persist currency and its drop as one transaction.
function M.save_provider_updates(updates, opts)
    opts = opts or {}
    local slot = opts.slot or M.slot or 1
    if slot ~= M.slot then return false, "snapshot_slot_mismatch" end
    local data = ensure_defaults(deep_copy(M.data))
    data.meta.providers = data.meta.providers or {}
    local now = os.time and os.time() or 0
    for id, value in pairs(updates or {}) do
        local provider = PROVIDERS[id]
        if not provider then return false, "unknown_provider:" .. tostring(id) end
        data.modules[id] = { version = provider.version, data = copy_for_storage(value) }
        data.meta.providers[id] = { version = provider.version, captured = now }
        if provider.mirror_key then data[provider.mirror_key] = copy_for_storage(value) end
    end
    drop_retired_provider_data(data)
    local saved, err = write_snapshot(slot, data)
    if saved then M.data = data end
    return saved, err
end

function M.save(slot_or_opts, maybe_opts)
    if save_batch_depth > 0 then return true end
    local slot = M.slot or 1
    local opts = nil
    if type(slot_or_opts) == "table" and maybe_opts == nil then
        opts = slot_or_opts
    elseif type(slot_or_opts) == "number" then
        slot = slot_or_opts
        if type(maybe_opts) == "table" then
            opts = maybe_opts
        end
    elseif slot_or_opts ~= nil then
        opts = type(maybe_opts) == "table" and maybe_opts or {}
        opts.reason = opts.reason or tostring(slot_or_opts)
    end
    opts = opts or {}
    if type(opts.slot) == "number" then
        slot = opts.slot
    end
    slot = math.max(1, math.floor(slot or 1))

    if save_suspension then
        if opts.reason == "game_exit" and slot == M.slot then return M.flush_suspended_save() end
        return false, "save_suspended:" .. tostring(save_suspension.reason)
    end
    M.slot = slot
    local existing, blocked, source = M.inspect_slot(slot)
    if blocked == "missing" then blocked_slots[slot] = nil end
    if blocked_slots[slot] then return false, blocked_slots[slot] end
    if blocked and blocked ~= "missing" and blocked ~= "corrupt" then
        M.last_error = blocked
        return false, blocked
    end

    M.data = ensure_defaults(M.data)
    drop_retired_provider_data(M.data)
    M.capture_from_runtime()

    local now = os.time and os.time() or 0
    local dt = (now - (SESSION_START or now))
    M.data.meta = M.data.meta or {}
    M.data.meta.version = M.VERSION
    M.data.meta.game_id = SavePaths.game_id() ~= "" and SavePaths.game_id() or nil
    M.data.meta.playtime_s = math.max(0, (M.data.meta.playtime_s or 0) + (dt or 0))
    M.data.meta.last_saved = now
    M.data.meta.last_reason = opts.reason
    M.data.meta.providers = M.data.meta.providers or {}
    SESSION_START = now

    local capture_context = {
        slot = slot,
        reason = opts.reason,
        timestamp = now,
        source = "save",
    }
    local modules, provider_meta = capture_providers(capture_context)
    M.data.modules = modules
    for id, meta in pairs(provider_meta) do
        M.data.meta.providers[id] = meta
    end

    return write_snapshot(slot, M.data, { existing = existing, source = source })
end


-- Load game from a slot
-- slot: Slot number to load (1-3), defaults to current slot
--
-- Returns: true if load successful, false if no save found
--
-- If no save exists in the slot, resets to default state.
-- Automatically applies all registered providers and updates M.data.
--
-- Example:
--   if Checkpoint.load(1) then
--     print("Loaded save slot 1")
--   else
--     print("No save found, using defaults")
--   end
function M.load(slot)
    slot = slot or M.slot or 1
    slot = math.max(1, math.floor(tonumber(slot) or 1))
    local key = M.key_for(slot)
    local context = {
        slot = slot,
        reason = "load",
        source = "load",
    }

    local function accept(original, source)
        local upgraded, data, reason = pcall(Migrations.upgrade, original, PROVIDERS,
            SavePaths.game_id(), MigrationConfig.identifier_aliases, saved_hash)
        if not upgraded or not data then
            M.last_error = tostring(upgraded and reason or data)
            blocked_slots[slot] = M.last_error
            return false, M.last_error
        end
        if compute_checksum(original) ~= compute_checksum(data) then
            local preserved, err = preserve_upgrade_backup(key, original)
            if not preserved then M.last_error = err; blocked_slots[slot] = err; return false, err end
        end
        if source == "backup" then
            local restored, result = pcall(sys.save, key, original)
            if not restored or result == false then return false, "Backup restore failed" end
        end
        data = ensure_defaults(data)
        blocked_slots[slot] = nil
        data.meta.checksum = compute_checksum(data)
        M.data = data
        apply_providers(data.modules, context)
        M.slot = slot
        SESSION_START = os.time and os.time() or 0
        pcall(sys.save, M.last_slot_key(), { slot = M.slot })
        return true
    end

    local data, reason, source = M.inspect_slot(slot)
    M.last_error = reason
    if data then return accept(data, source) end
    if reason ~= "missing" and reason ~= "corrupt" then blocked_slots[slot] = reason; return false, reason end

    -- Nothing valid found; reset runtime state to defaults.
    M.data = ensure_defaults(nil)
    blocked_slots[slot] = nil
    apply_providers(nil, { slot = slot, reason = "reset", source = "reset" })
    return false
end

function M.apply(player_url, opts)
    M.data = ensure_defaults(M.data)
    player_url = player_url or (C.URL and C.URL.PLAYER)
    if not (opts and opts.skip_position) and player_url and go.exists(player_url) and M.data.checkpoint then
        local p = vmath.vector3(M.data.checkpoint.x or 0, M.data.checkpoint.y or 0, 0)
        print(string.format("[CHECKPOINT] Applying checkpoint position: (%.1f, %.1f) to player", p.x, p.y))
        
        msg.post(player_url, C.MSG and C.MSG.SET_POSITION or hash("mvtk_set_position"), {
            position = p, room_id = M.data.checkpoint.room_id,
        })
    else
        print(string.format("[CHECKPOINT] Cannot apply - player_url=%s, exists=%s, has_checkpoint=%s", 
            tostring(player_url), 
            tostring(player_url and go.exists(player_url)), 
            tostring(M.data.checkpoint ~= nil)))
    end
    -- Restore minimap explored state
    local mini = rawget(_G, "MINIMAP_MODULE")
    if mini then mini.explored = Discovery.explored end
    -- Restore minimap view center
    if mini and M.data.minimap_view_center then
        local vc = M.data.minimap_view_center
        if mini.set_view_center_world then
            mini.set_view_center_world(vc.x, vc.y)
        end
        if mini.request_view_center_world then
            mini.request_view_center_world(vc.x, vc.y)
        end
    end
end

function M.autosave(reason)
    return M.save(nil, { reason = reason or "autosave" })
end

function M.list_slots(max_slots)
    local n = max_slots or 3
    local out = {}
    for s = 1, n do
        local data, reason = M.inspect_slot(s)
        local exists = data ~= nil
        out[#out + 1] = { slot = s, exists = exists, meta = exists and data.meta or nil, error = reason }
    end
    return out
end

function M.last_slot()
    local key = M.last_slot_key()
    local ok, data = pcall(sys.load, key)
    return (ok and type(data) == 'table' and tonumber(data.slot)) or nil
end

-- Re-apply all providers to already-loaded data
-- This is useful when providers are registered after the initial load
-- (e.g., screenshot_markers is registered when main.script loads,
-- but checkpoint data was already loaded in save slot selection screen)
function M.reapply_providers()
    if not M.data or not M.data.modules then
        return false
    end
    local context = {
        slot = M.slot,
        reason = "reapply",
        source = "reapply",
    }
    -- Late registration must obey the same provider version contract as load.
    local ok, upgraded, reason = pcall(Migrations.upgrade, M.data, PROVIDERS,
        SavePaths.game_id(), MigrationConfig.identifier_aliases, saved_hash)
    if not ok or not upgraded then
        M.last_error = tostring(ok and reason or upgraded)
        blocked_slots[M.slot] = M.last_error
        return false, M.last_error
    end
    if compute_checksum(M.data) ~= compute_checksum(upgraded) then
        local read_ok, original = pcall(sys.load, M.key_for(M.slot))
        if read_ok and is_saved_payload(original) then
            local preserved, err = preserve_upgrade_backup(M.key_for(M.slot), original)
            if not preserved then blocked_slots[M.slot] = err; return false, err end
        end
        M.data = upgraded
        M.data.meta.checksum = compute_checksum(M.data)
    end
    apply_providers(M.data.modules, context)
    return true
end

function M.reset(slot)
    M.resume_saves()
    if slot then
        M.set_slot(slot)
    end
    M.data = new_data()
    apply_providers(nil, { slot = M.slot, reason = "reset", source = "reset" })
end

local function restore_discovery(data)
    Discovery.restore(data, M.data.explored)
    local mini = rawget(_G, "MINIMAP_MODULE")
    if mini then mini.explored = Discovery.explored end
end
M.register_provider("map_discovery", {
    capture = Discovery.capture,
    apply = restore_discovery,
    defaults = function() restore_discovery(nil) end,
    version = 1,
    order = 30,
    description = "Visited rooms and persistent fog of war",
})

return M
