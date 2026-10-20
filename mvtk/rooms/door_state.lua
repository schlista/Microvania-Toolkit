-- mvtk/rooms/door_state.lua
-- ============================================================================
-- Door State Registry
-- ============================================================================
-- Runtime registry tracking which doors have been opened.
-- Persists door states through save/load system and integrates with flags.
--
-- Features:
--   - Track opened doors by door_id
--   - Listener pattern for door state changes
--   - Automatic persistence through checkpoint system
--   - Integration with flags system for permanence
--
-- Usage:
--   DoorState.open_edge("door_001")  -- Mark door as opened
--   if DoorState.is_open("door_001") then ... end
--   DoorState.listen("door_001", self_url)  -- Get notified when door opens
--
-- Door ids are stored and published as authored text.

local Util = require "mvtk.core.util"
local FlagsOk, Flags = pcall(require, "mvtk.core.flags")

local M = {
    open = {},      -- [door_id_text] = true  (opened doors)
    listeners = {}, -- [door_id_text] = {[url] = true, ...}  (listeners per door)
}

-- ============================================================================
-- CONSTANTS
-- ============================================================================

-- Message sent to listeners when a door opens
local OPENED_MSG = hash("mvtk_door_opened")

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

-- Normalize authored ids without creating hash or hexadecimal save keys.
local function normalize_door_id(door_id)
    return Util.normalize_hash_string(door_id)
end

local function flatten_open_list(data)
    local out = {}
    if type(data) ~= "table" then return out end
    if data.open ~= nil then
        data = data.open
    end
    local seen = {}
    local function push(door_id)
        if not door_id then return end
        local key = tostring(door_id)
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = door_id
    end
    for i = 1, #data do
        push(normalize_door_id(data[i]))
    end
    for k, v in pairs(data) do
        if type(k) ~= "number" then
            if v then
                push(normalize_door_id(k))
            end
        elseif k > #data then
            push(normalize_door_id(v))
        end
    end
    table.sort(out, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return out
end

-- Notify all listeners that a door has opened
-- door_id: Normalized door id (text)
--
-- Sends "mvtk_door_opened" message to all registered listeners for this door.
-- Automatically skips listeners whose game objects no longer exist.
local function notify(door_id)
    local lst = M.listeners[door_id]
    if not lst then return end

    for url, _ in pairs(lst) do
        if url and go.exists(url) then
            pcall(msg.post, url, OPENED_MSG, { door_id = door_id })
        end
    end
end

-- Store door open state in flags system (for permanence across saves)
-- door_id: Normalized door id (text)
local function store_open_flag(door_id)
    if FlagsOk and Flags and Flags.set then
        Flags.set(door_id, true)
    end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Reset all door states and listeners
-- Clears all opened doors and listener registrations.
-- Use when starting a new game or resetting to defaults.
function M.reset()
    M.open = {}
    M.listeners = {}
end

-- Check if a door is open
-- door_id: Authored door identifier
-- Returns: true if door is open, false otherwise
--
-- Checks both runtime state and persistent flags system.
function M.is_open(door_id)
    door_id = normalize_door_id(door_id)

    -- Check runtime state first
    if M.open[door_id] == true then return true end

    -- Fall back to flags system (persistent)
    if FlagsOk and Flags and Flags.has and door_id then
        return Flags.has(door_id)
    end

    return false
end

-- Mark a door as opened
-- door_id: Authored door identifier
--
-- Opens the door, persists to flags, and notifies all listeners.
-- Idempotent - safe to call multiple times for the same door.
function M.open_edge(door_id)
    door_id = normalize_door_id(door_id)
    if not door_id then return end

    -- Already open - do nothing
    if M.open[door_id] then return end

    -- Mark as open
    M.open[door_id] = true

    -- Persist to flags system
    store_open_flag(door_id)

    -- Notify listeners
    notify(door_id)
end

-- ============================================================================
-- SAVE/LOAD SUPPORT
-- ============================================================================

-- Export door states for saving
-- Returns: Table {open = {door_id1, door_id2, ...}} of all opened doors
--
-- Used by checkpoint system to save door states.
function M.export()
    local list = {}
    for door_id, open in pairs(M.open) do
        if open then
            list[#list + 1] = door_id
        end
    end

    -- Sort for deterministic save files
    table.sort(list, function(a, b)
        return tostring(a) < tostring(b)
    end)

    return { open = list }
end

-- Import door states from save data
-- data: Table returned from export() or save file
--
-- Used by checkpoint system to restore door states.
-- Clears existing door states and loads from data.
function M.import(data)
    local list = flatten_open_list(data)
    M.open = {}

    -- Restore each opened door
    for _, door_id in ipairs(list) do
        M.open[door_id] = true
        store_open_flag(door_id)
    end
end

-- ============================================================================
-- LISTENER PATTERN
-- ============================================================================

-- Register to be notified when a door opens
-- door_id: Authored door identifier
-- url: Game object URL to send notifications to
--
-- If door is already open, immediately sends notification.
-- Listener receives "mvtk_door_opened" message with {door_id = door_id} payload.
function M.listen(door_id, url)
    door_id = normalize_door_id(door_id)
    if not (door_id and url) then return end

    -- Register listener
    M.listeners[door_id] = M.listeners[door_id] or {}
    M.listeners[door_id][url] = true

    -- If door already open, notify immediately
    if M.is_open(door_id) then
        pcall(msg.post, url, OPENED_MSG, { door_id = door_id })
    end
end

-- Unregister from door open notifications
-- door_id: Authored door identifier
-- url: Game object URL to stop notifying
function M.unlisten(door_id, url)
    door_id = normalize_door_id(door_id)
    if not (door_id and url) then return end

    local lst = M.listeners[door_id]
    if not lst then return end

    -- Remove listener
    lst[url] = nil

    -- Clean up empty listener table
    if not next(lst) then
        M.listeners[door_id] = nil
    end
end

local function register_with_checkpoint()
    local ok, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if not ok or not Checkpoint or not Checkpoint.register_provider then
        return
    end
    Checkpoint.register_provider("door_state", {
        capture = function()
            return M.export()
        end,
        apply = function(payload)
            M.import(payload)
        end,
        defaults = function()
            M.reset()
        end,
        version = 1,
        order = 60,
        mirror_key = "doors",
        description = "Door open-state registry",
    })
end

register_with_checkpoint()

return M
