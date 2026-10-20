--- NPC Manager
-- Central NPC system for dialogue
-- Integrates with Tiled object spawning
--

local Util = require "mvtk.core.util"

local M = {}
local C = require "mvtk.core.constants"

-- Debug-gate all print() calls in this module so they only fire when enabled.
-- Matches the legacy `Debug.global.enable OR Debug.gameplay.npcs` pattern --
-- the master switch must enable NPC logs even when the per-flag is false.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    local global_on = _Dbg.global and _Dbg.global.enable
    local npcs_on = _Dbg.gameplay and _Dbg.gameplay.npcs
    if global_on or npcs_on then
        _orig_print(...)
    end
end

-- Active NPCs registry
local active_npcs = {}  -- npc_id -> npc_data
local npc_configs = {}  -- NPC type configurations

-- Forward declaration
local count_keys

local normalize_text = Util.normalize_hash_string

local function pick_text(primary, fallback, default)
    return normalize_text(primary) or normalize_text(fallback) or default
end

local function pick_number(primary, fallback, default)
    local value = tonumber(primary)
    if value ~= nil then
        return value
    end
    value = tonumber(fallback)
    if value ~= nil then
        return value
    end
    return default
end

local function component_exists(component_url)
    if not component_url then
        return false
    end

    local url = component_url
    if type(url) == "string" then
        local ok_url, parsed = pcall(msg.url, url)
        if not ok_url then
            return false
        end
        url = parsed
    end

    if type(url) ~= "userdata" then
        return false
    end

    local go_url = msg.url(url.socket, url.path, nil)
    return go_url and pcall(go.exists, go_url) and go.exists(go_url) or false
end

--- Initialize NPC system
function M.init()
    print("[NPC_MANAGER] Initializing NPC system...")

    -- Load NPC type definitions
    local ok, NPCTypes = pcall(require, "developer.config.npc_types")
    if ok and type(NPCTypes) == "table" then
        npc_configs = NPCTypes
        print(string.format("[NPC_MANAGER] Loaded %d NPC type definitions", count_keys(npc_configs)))
    else
        print("[NPC_MANAGER] WARNING: developer/config/npc_types.lua not found or invalid")
        print("[NPC_MANAGER] HINT: Create this file to define NPC types. Example:")
        print([[  return {
    elder    = { name = "Elder",    sprite = "npc_elder",    dialogue_id = "elder_dialogue" },
  }]])
        npc_configs = {}
    end

    -- Subscribe to room unload so per-room NPC entries get cleaned up
    -- automatically. Idempotent: register_event allows multiple init() calls
    -- but each registration adds another listener, so guard with a flag.
    if not M._room_lifecycle_wired then
        local ok_rm, RoomManager = pcall(require, "mvtk.map.streaming.room_manager")
        if ok_rm and RoomManager and RoomManager.on_room_unload then
            RoomManager.on_room_unload(function(room_id)
                M.unload_room(room_id)
            end)
            M._room_lifecycle_wired = true
        end
    end
end

count_keys = function(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

--- Spawn an NPC
-- @param npc_id Unique NPC identifier
-- @param npc_type NPC type ID (from npc_types.lua)
-- @param position World position
-- @param config Optional instance configuration
-- @return Spawned NPC data or nil
function M.spawn_npc(npc_id, npc_type, position, config)
    if not npc_id then
        print("[NPC_MANAGER] ERROR: Missing npc_id")
        return nil
    end

    config = config or {}

    local resolved_type = normalize_text(npc_type) or ""
    local npc_def = npc_configs[resolved_type] or {}
    if resolved_type ~= "" and not npc_configs[resolved_type] then
        print(string.format("[NPC_MANAGER] WARNING: Unknown NPC type '%s' - using Tiled-authored properties", resolved_type))
    end
    
    -- Merge configuration
    local npc = {
        id = npc_id,
        type = resolved_type ~= "" and resolved_type or "inline_npc",
        position = vmath.vector3(position),
        room_id = config.room_id,
        
        -- NPC properties
        name = pick_text(config.name, npc_def.name, "NPC"),
        sprite = pick_text(config.sprite, npc_def.sprite, "npc_idle"),
        dialogue_id = pick_text(config.dialogue_id, npc_def.dialogue_id, nil),

        -- State
        interactable = true,
        busy = false,
        busy_reason = nil,
        facing = pick_number(config.facing, npc_def.facing, 1),  -- 1 = right, -1 = left
        interaction_range = pick_number(config.interaction_range, npc_def.interaction_range, 48),
        
        -- Game object URL (set when spawned)
        url = nil,
    }
    
    active_npcs[npc_id] = npc
    
    print(string.format("[NPC_MANAGER] Spawned NPC '%s' (type: %s) at (%.0f, %.0f)",
        npc_id, npc.type, position.x, position.y))
    
    return npc
end

--- Register NPC game object instance
-- @param npc_id NPC identifier
-- @param npc_url Game object URL
function M.register_instance(npc_id, npc_url)
    local npc = active_npcs[npc_id]
    if npc then
        npc.url = npc_url
        print(string.format("[NPC_MANAGER] Registered NPC instance: %s", npc_id))
    end
end

--- Interact with NPC
-- @param npc_id NPC identifier
-- @param player_url Player game object URL
-- @return true if interaction started
function M.interact(npc_id, player_url)
    local npc = active_npcs[npc_id]
    if not npc then return false end

    -- Recover NPCs that were left busy by older code paths before busy_reason existed.
    if npc.busy and npc.busy_reason == nil then
        npc.busy = false
    end
    
    if not npc.interactable or npc.busy then
        return false
    end
    
    print(string.format("[NPC_MANAGER] Interacting with NPC: %s", npc_id))
    
    -- Check for dialogue
    if npc.dialogue_id and npc.dialogue_id ~= "" then
        M.start_dialogue(npc_id, player_url)
        return true
    end
    
    -- Default generic interaction
    print(string.format("[NPC_MANAGER] %s: Hello, traveler!", npc.name))
    return true
end

--- Start dialogue with NPC
-- @param npc_id NPC identifier
-- @param player_url Player game object URL
function M.start_dialogue(npc_id, player_url)
    local npc = active_npcs[npc_id]
    if not npc or not npc.dialogue_id or npc.dialogue_id == "" then
        return false
    end
    
    npc.busy = true
    npc.busy_reason = "dialogue"
    
    print(string.format("[NPC_MANAGER] Starting dialogue: %s", npc.dialogue_id))
    
    -- Post to dialogue system (optional - gracefully handle if not present)
    local success, error_msg = pcall(function()
        local dialogue_url = C.url("DIALOGUE_MANAGER")
        if not dialogue_url or not component_exists(dialogue_url) then
            print("[NPC_MANAGER] WARNING: dialogue_manager URL not set - dialogue system disabled")
            error("dialogue_manager_unavailable")
        end
        
        msg.post(dialogue_url, hash("start_dialogue"), {
            dialogue_id = npc.dialogue_id,
            npc_id = npc_id,
            npc_name = npc.name,
            player_url = player_url
        })
    end)
    
    if not success then
        print(string.format("[NPC_MANAGER] Dialogue system unavailable: %s", tostring(error_msg)))
        npc.busy = false
        npc.busy_reason = nil
        return false
    end

    return true
end

--- End dialogue with NPC
-- @param npc_id NPC identifier
function M.end_dialogue(npc_id)
    local npc = active_npcs[npc_id]
    if npc then
        npc.busy = false
        npc.busy_reason = nil
        print(string.format("[NPC_MANAGER] Ended dialogue with: %s", npc_id))
    end
end

--- Get NPC data
-- @param npc_id NPC identifier
-- @return NPC data or nil
function M.get_npc(npc_id)
    return active_npcs[npc_id]
end

--- Get all NPCs
-- @return Table of all active NPCs
function M.get_all_npcs()
    return active_npcs
end

--- Despawn NPC
-- @param npc_id NPC identifier
function M.despawn_npc(npc_id)
    local npc = active_npcs[npc_id]
    if not npc then return end
    
    -- Delete game object if exists
    if npc.url and go.exists(npc.url) then
        go.delete(npc.url)
    end
    
    active_npcs[npc_id] = nil
    print(string.format("[NPC_MANAGER] Despawned NPC: %s", npc_id))
end

--- Unload all NPCs in a room
-- @param room_id Room identifier
function M.unload_room(room_id)
    local count = 0
    local to_remove = {}
    
    for npc_id, npc in pairs(active_npcs) do
        if npc.room_id == room_id then
            table.insert(to_remove, npc_id)
        end
    end
    
    for _, npc_id in ipairs(to_remove) do
        M.despawn_npc(npc_id)
        count = count + 1
    end
    
    if count > 0 then
        print(string.format("[NPC_MANAGER] Unloaded %d NPCs from room: %s", count, room_id))
    end
end

--- Clear all NPCs
function M.clear_all()
    for npc_id, _ in pairs(active_npcs) do
        M.despawn_npc(npc_id)
    end
    print("[NPC_MANAGER] Cleared all NPCs")
end

return M
