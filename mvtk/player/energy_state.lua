-- mvtk/player/energy_state.lua
-- ============================================================================
-- Energy Resource System
-- ============================================================================
-- Centralized energy resource tracking shared between player, gates, and UI.
-- Manages current/max energy with listener notifications for UI updates.
--
-- Energy is used for:
--   - Unlocking energy gates (progression)
--   - Special abilities (dashes, attacks, etc.)
--   - UI display (energy bar)
--
-- Features:
--   - Add/consume energy with automatic clamping
--   - Increase max energy (permanent upgrades)
--   - Listener callbacks for real-time UI updates
--   - Automatic HUD synchronization
--
-- Usage:
--   EnergyState.init({current = 0, max = 100})
--   EnergyState.add(25)  -- Add 25 energy
--   EnergyState.consume(10)  -- Use 10 energy (returns true if successful)
--   EnergyState.register_listener(function(payload) ... end)

local Util = require "mvtk.core.util"

local EnergyState = {}

-- ============================================================================
-- STATE
-- ============================================================================

-- Current energy amount (0 to max_energy)
local current_energy = 0

-- Maximum energy capacity
local max_energy = 0

-- Registered listener callbacks (called on energy changes)
local listeners = {}
local next_listener_id = 1

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

-- Notify all listeners of an energy change event
-- event: Event name ("init", "add", "consume", "set", "increase_max")
-- amount: Amount changed (can be nil)
-- reason: Optional reason string (e.g., "pickup", "ability_use")
local function notify(event, amount, reason)
    -- Build payload with event data
    local payload = {
        event = event,  -- Event type
        amount = amount,  -- Amount changed (nil for set/init)
        reason = reason,  -- Why it changed (optional)
        current = current_energy,  -- Current energy after change
        max = max_energy,  -- Max energy after change
    }

    -- Call all registered listeners (protected to prevent one from breaking others)
    for id, callback in pairs(listeners) do
        local ok, err = pcall(callback, payload)
        if not ok then
            print(string.format("[ENERGY_STATE] Listener %s failed: %s", tostring(id), tostring(err)))
        end
    end

    -- Update HUD energy display (safe even if HUD isn't loaded yet)
    pcall(msg.post, "main:/mode_hud#mode_hud", hash("hud_energy"), {
        energy = current_energy,
        energy_max = max_energy,
    })
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

-- Initialize energy system with starting values
-- opts: Optional table with fields:
--   current: Starting energy amount (default: 0)
--   max: Maximum energy capacity (default: 0)
--
-- Call this at game start or when loading a save.
function EnergyState.init(opts)
    opts = opts or {}
    local new_max = Util.clamp(tonumber(opts.max) or max_energy, 0, math.huge)
    local new_current = Util.clamp(tonumber(opts.current) or current_energy, 0, new_max)
    max_energy = new_max
    current_energy = new_current
    notify("init")
end

-- ============================================================================
-- SETTERS
-- ============================================================================

-- Set energy values directly (bypassing add/consume logic)
-- current: New current energy (nil to keep current value)
-- max: New max energy (nil to keep current value)
--
-- Use this for loading save data or debug commands.
-- For normal gameplay, prefer add(), consume(), and increase_max().
function EnergyState.set(current, max)
    if max ~= nil then
        max_energy = Util.clamp(tonumber(max) or max_energy, 0, math.huge)
    end
    if current ~= nil then
        current_energy = Util.clamp(tonumber(current) or current_energy, 0, max_energy)
    else
        -- If only max changed, re-clamp current to new max
        current_energy = Util.clamp(current_energy, 0, max_energy)
    end
    notify("set")
end

-- Set maximum energy capacity
-- max: New max energy value
function EnergyState.set_max(max)
    EnergyState.set(nil, max)
end

-- Set current energy amount
-- current: New current energy value
function EnergyState.set_current(current)
    EnergyState.set(current, nil)
end

-- ============================================================================
-- ENERGY MODIFICATION
-- ============================================================================

-- Add energy (from pickups, regeneration, etc.)
-- amount: Amount to add (can be negative to subtract)
-- opts: Optional table with fields:
--   reason: String describing why energy was added (for debugging/UI)
-- Returns: Actual amount added (may be less if hit max)
--
-- Example:
--   EnergyState.add(10, {reason = "energy_pickup"})
function EnergyState.add(amount, opts)
    amount = tonumber(amount) or 0
    if amount == 0 then return 0 end

    local before = current_energy
    current_energy = Util.clamp(current_energy + amount, 0, max_energy)

    notify("add", current_energy - before, opts and opts.reason)
    return current_energy - before  -- Return actual amount added
end

-- Increase maximum energy capacity (permanent upgrade)
-- amount: Amount to increase max by
-- opts: Optional table with fields:
--   fill: If true, also increases current energy by amount
--   reason: String describing why max increased
-- Returns: Actual amount max was increased
--
-- Example:
--   EnergyState.increase_max(25, {fill = true, reason = "upgrade_orb"})
function EnergyState.increase_max(amount, opts)
    amount = tonumber(amount) or 0
    if amount == 0 then return 0 end

    local before = max_energy
    max_energy = Util.clamp(max_energy + amount, 0, math.huge)

    -- Optionally fill the new capacity immediately
    if opts and opts.fill then
        current_energy = Util.clamp(current_energy + amount, 0, max_energy)
    else
        -- Re-clamp current in case max decreased (unusual but possible)
        current_energy = Util.clamp(current_energy, 0, max_energy)
    end

    notify("increase_max", max_energy - before, opts and opts.reason)
    return max_energy - before  -- Return actual amount max increased
end

-- ============================================================================
-- ENERGY CONSUMPTION
-- ============================================================================

-- Check if player has at least the specified amount of energy
-- amount: Amount to check for
-- Returns: true if has enough energy, false otherwise
function EnergyState.has(amount)
    amount = tonumber(amount) or 0
    if amount <= 0 then return true end  -- Always have zero or negative energy
    return current_energy >= amount
end

-- Consume energy (for abilities, gates, etc.)
-- amount: Amount to consume
-- opts: Optional table with fields:
--   reason: String describing why energy was consumed
-- Returns: true if consumed successfully, false if insufficient energy
--
-- Example:
--   if EnergyState.consume(15, {reason = "air_dash"}) then
--     -- Perform dash
--   else
--     -- Not enough energy
--   end
function EnergyState.consume(amount, opts)
    amount = tonumber(amount) or 0
    if amount <= 0 then
        return true  -- Consuming zero/negative always succeeds
    end

    -- Check if enough energy available
    if current_energy < amount then
        return false  -- Insufficient energy
    end

    -- Consume the energy
    current_energy = Util.clamp(current_energy - amount, 0, max_energy)
    notify("consume", amount, opts and opts.reason)
    return true
end

-- ============================================================================
-- GETTERS
-- ============================================================================

-- Get current and max energy values
-- Returns: current_energy, max_energy
function EnergyState.get()
    return current_energy, max_energy
end

-- ============================================================================
-- LISTENER MANAGEMENT
-- ============================================================================

-- Register a callback to be notified of energy changes
-- callback: Function(payload) where payload contains:
--   event: Event name ("init", "add", "consume", "set", "increase_max")
--   amount: Amount changed (can be nil)
--   reason: Why it changed (optional string)
--   current: Current energy after change
--   max: Max energy after change
-- Returns: Listener ID (use to unregister later), or nil if callback invalid
--
-- Example:
--   local id = EnergyState.register_listener(function(payload)
--     print("Energy event:", payload.event, payload.current, "/", payload.max)
--   end)
function EnergyState.register_listener(callback)
    if type(callback) ~= "function" then
        return nil
    end
    local id = next_listener_id
    next_listener_id = next_listener_id + 1
    listeners[id] = callback
    return id
end

-- Unregister a listener callback
-- id: Listener ID returned from register_listener()
function EnergyState.unregister_listener(id)
    if not id then return end
    listeners[id] = nil
end

return EnergyState
