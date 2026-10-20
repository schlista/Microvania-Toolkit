-- mvtk/developer/game/save_system/save_manager.lua
-- Save system manager bridging Checkpoint and user settings.

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })
local Config = Util.require_config("developer.config.resolved_config")
local Checkpoint = require "mvtk.core.checkpoint"
local Settings = require "mvtk.core.settings"

local M = {}

local save_log = Util.make_debug_log("[SAVE]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.save_manager)
end)

local SAVE_SLOTS = (Config.progression and Config.progression.saves and Config.progression.saves.max_slots) or 3

local function resolve_slot(slot)
    if slot == nil then return Checkpoint.slot or 1 end
    return slot
end

local function valid_slot(slot)
    return type(slot) == "number" and slot == slot and slot % 1 == 0 and slot >= 1 and slot <= SAVE_SLOTS
end

-- A value <= 0 disables wall-clock saves. Progression/checkpoint events still
-- save normally, avoiding a synchronous disk write in the middle of movement.
local AUTO_SAVE_INTERVAL = (Config.progression and Config.progression.saves and Config.progression.saves.autosave_interval) or 30
local auto_save_timer = 0
local TOMBSTONE_FLAG = "__deleted"

local function make_tombstone()
    return {
        [TOMBSTONE_FLAG] = true,
        deleted_at = os.time and os.time() or 0,
    }
end

-- Backup recovery uses the same version/ownership checks as Continue.
local function restore_backup(slot)
    local _, reason = Checkpoint.inspect_slot(slot)
    if reason and reason ~= "missing" and reason ~= "corrupt" then return false, reason end
    local path = Checkpoint.key_for(slot)
    local ok, data = pcall(sys.load, path .. "_backup")
    if not ok or not Checkpoint.validate_saved(data) then return false end
    local saved, result = pcall(sys.save, path, data)
    return saved and result ~= false
end

function M.merge_defaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then
            target[key] = value
        elseif type(value) == "table" and type(target[key]) == "table" then
            M.merge_defaults(target[key], value)
        end
    end
end

local function load_slot_data(slot)
    return Checkpoint.inspect_slot(slot)
end

function M.init()
    if Checkpoint.is_save_suspended() then
        local saved, err = Checkpoint.flush_suspended_save()
        if not saved then return false, err end
    end
    save_log("[SAVE_MANAGER] Initializing save system...")
    M.load_settings()
    auto_save_timer = 0
    local current_slot = 1

    -- Check if Checkpoint already has a slot set (from save slot selection screen)
    local checkpoint_slot = Checkpoint.slot
    if checkpoint_slot and checkpoint_slot >= 1 then
        current_slot = checkpoint_slot
        save_log(string.format("[SAVE_MANAGER] Using slot %d from Checkpoint", current_slot))
    else
        -- Try to load last used slot
        local last = Checkpoint.last_slot and Checkpoint.last_slot() or nil
        if last then
            current_slot = math.max(1, math.min(SAVE_SLOTS, last))
        end
    end
    
    Checkpoint.set_slot(current_slot)

    -- Check if checkpoint data is already loaded (from save slot selection)
    if Checkpoint.data and Checkpoint.data.meta and Checkpoint.data.meta.version then
        save_log(string.format("[SAVE_MANAGER] Checkpoint already loaded for slot %d", current_slot))
        -- Re-apply providers in case new providers registered after initial load
        -- (e.g., screenshot_markers registers when main.script loads, but checkpoint
        -- data was already loaded in save slot selection screen)
        Checkpoint.reapply_providers()
    elseif not Checkpoint.load(current_slot) then
        Checkpoint.reset(current_slot)
        Checkpoint.save({ slot = current_slot, reason = "new_save" })
        save_log(string.format("[SAVE_MANAGER] Created new save for slot %d", current_slot))
    else
        save_log(string.format("[SAVE_MANAGER] Loaded slot %d", current_slot))
    end
end

function M.set_current_slot(slot)
    if not valid_slot(slot) then
        save_log(string.format("[SAVE_MANAGER] Invalid save slot: %s", tostring(slot)))
        return false, "invalid_slot"
    end
    if slot ~= M.get_current_slot() and Checkpoint.is_save_suspended() then
        local saved, err = Checkpoint.flush_suspended_save()
        if not saved then return false, err end
    end
    Checkpoint.set_slot(slot)

    save_log(string.format("[SAVE_MANAGER] Changed to save slot: %d", slot))
    return true
end

function M.get_current_slot()
    -- Boot menus and checkpoint events also select slots. Keep one authority
    -- so later manual/timed saves follow the slot that was actually loaded.
    return resolve_slot(nil)
end

function M.create_new_save(slot)
    slot = resolve_slot(slot)
    if not valid_slot(slot) then return nil, "invalid_slot" end
    local _, reason = Checkpoint.inspect_slot(slot)
    if reason and reason ~= "missing" and reason ~= "corrupt" then return nil, reason end
    local selected, selection_error = M.set_current_slot(slot)
    if not selected then return nil, selection_error end
    Checkpoint.reset(slot)
    local saved, error_message = Checkpoint.save({ slot = slot, reason = "new_game" })
    if not saved then return nil, error_message end
    save_log(string.format("[SAVE_MANAGER] Created new save data for slot %d", slot))
    return Checkpoint.data
end

function M.save_game(slot)
    slot = resolve_slot(slot)

    local selected, selection_error = M.set_current_slot(slot)
    if not selected then return false, selection_error end
    -- Checkpoint.save now stamps the integrity checksum and rotates the _backup
    -- copy itself, so we no longer pre-backup or re-stamp here.
    local ok = Checkpoint.save({ slot = slot, reason = "manual_save" })
    if ok then
        save_log(string.format("[SAVE_MANAGER] Game saved to slot %d", slot))
    else
        save_log(string.format("[SAVE_MANAGER] Failed to save game to slot %d", slot))
        -- A failed write must not replace a newer or foreign primary save.
    end
    return ok
end

function M.load_game(slot)
    if Checkpoint.is_save_suspended() then
        local saved, err = Checkpoint.flush_suspended_save()
        if not saved then return false, err end
    end
    slot = resolve_slot(slot)
    local selected, selection_error = M.set_current_slot(slot)
    if not selected then return false, selection_error end
    local ok = Checkpoint.load(slot)
    if ok then
        save_log(string.format("[SAVE_MANAGER] Game loaded from slot %d", slot))
        return true
    end
    save_log(string.format("[SAVE_MANAGER] No save file found for slot %d", slot))
    return false
end

function M.has_save_data(slot)
    return load_slot_data(resolve_slot(slot)) ~= nil
end

function M.get_save_info(slot)
    local data = load_slot_data(resolve_slot(slot))
    if not data then
        return nil
    end
    local meta = data.meta or {}
    local modules = data.modules or {}
    local info = {
        slot = resolve_slot(slot),
        timestamp = meta.last_saved or meta.timestamp,
        playtime_s = meta.playtime_s,
    }
    local progression = modules.progression and modules.progression.data
    if progression and progression.level then
        info.level = progression.level
    end
    local world = modules.world and modules.world.data
    if world and world.current_room then
        info.room = world.current_room
    end
    return info
end

function M.delete_save(slot)
    slot = resolve_slot(slot)
    if not valid_slot(slot) then return false, "invalid_slot" end
    local path = Checkpoint.key_for(slot)
    local backup_path = path .. "_backup"
    local tombstone = make_tombstone()

    local function clear_key(key, label)
        local ok, err = pcall(sys.save, key, tombstone)
        if not ok or err == false then
            save_log(string.format("[SAVE_MANAGER] Failed to clear %s key for slot %d (%s): %s",
                label, slot, tostring(key), tostring(err)))
            return false
        end
        return true
    end

    local ok_primary = clear_key(path, "primary")
    local ok_backup = clear_key(backup_path, "backup")

    if not (ok_primary and ok_backup) then
        save_log(string.format("[SAVE_MANAGER] Failed to fully delete save data from slot %d", slot))
        return false
    end

    save_log(string.format("[SAVE_MANAGER] Deleted save data from slot %d", slot))
    if slot == M.get_current_slot() then
        Checkpoint.reset(slot)
    end

    return true
end

function M.save_settings()
    return Settings.save()
end

function M.load_settings()
    local _, loaded = Settings.load()
    return loaded
end

function M.get_save_data()
    return Checkpoint.data
end

function M.get_module_data(name)
    local data = Checkpoint.data
    local modules = data and data.modules
    local entry = modules and modules[name]
    return entry and entry.data or nil
end

function M.get_settings()
    return Settings.data()
end

function M.update_save_data(key, value)
    local target = Checkpoint.data
    if not target then
        Checkpoint.reset(M.get_current_slot())
        target = Checkpoint.data
    end

    local current = target
    local segments = {}
    for segment in key:gmatch("([^.]+)") do
        segments[#segments + 1] = segment
    end

    for i = 1, #segments - 1 do
        local segment = segments[i]
        current[segment] = current[segment] or {}
        current = current[segment]
    end

    local last = segments[#segments]
    if last then
        current[last] = value
    end
end

function M.on_room_changed(previous,current)
    local saves=Config.progression and Config.progression.saves or {}
    if previous and current and previous~=current and saves.autosave_on_room_change==true then
        return Checkpoint.autosave("room_change")
    end
    return false
end

function M.update(dt)
    if Checkpoint.is_save_suspended() then return end
    local settings_data = Settings.data()
    local autosave_allowed = not (Config.progression and Config.progression.saves and Config.progression.saves.autosave_enabled == false)
    if AUTO_SAVE_INTERVAL > 0
        and autosave_allowed
        and settings_data
        and settings_data.gameplay
        and settings_data.gameplay.auto_save
    then
        auto_save_timer = auto_save_timer + dt
        if auto_save_timer >= AUTO_SAVE_INTERVAL then
            M.save_game()
            auto_save_timer = 0
        end
    end
end

-- Restore from backup (can be called manually if needed)
function M.restore_backup(slot)
    slot = resolve_slot(slot)
    if not valid_slot(slot) then return false, "invalid_slot" end
    return restore_backup(slot)
end

return M
