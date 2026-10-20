-- Landing-only persistence for persistent elevators.
--
-- The runtime never serializes a cabin mid-shaft. Completed bottom/top stops
-- are captured through the checkpoint provider system under their authored
-- elevator IDs. The in-memory table remains usable when Checkpoint is absent
-- (for standalone tests or stripped integrations).

local State = require "mvtk.elevators.elevator_state"

local M = {}

local PROVIDER_ID = "elevators"
local landings = {}
local checkpoint_registered = false
local listeners = {}

local function notify(reason)
    for _, listener in pairs(listeners) do
        pcall(listener, reason)
    end
end

local function authored_key(elevator_id)
    if type(elevator_id) ~= "string" or elevator_id == "" then return nil end
    return elevator_id
end

local function copy_landings(source)
    local result = {}
    for elevator_id, stop in pairs(type(source) == "table" and source or {}) do
        local key = authored_key(elevator_id)
        local normalized = State.normalize_stop(stop)
        if key and normalized then result[key] = normalized end
    end
    return result
end

local function checkpoint_module()
    local ok, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if not ok or type(Checkpoint) ~= "table" then return nil end
    return Checkpoint
end

local function snapshot()
    return { landings = copy_landings(landings) }
end

local function mirror_checkpoint_data()
    local Checkpoint = checkpoint_module()
    if not Checkpoint or type(Checkpoint.data) ~= "table" then return false end
    Checkpoint.data.elevators = snapshot()
    return true
end

function M.capture_state()
    return snapshot()
end

function M.apply_state(payload)
    if type(payload) ~= "table" then
        landings = {}
        notify("apply")
        return false
    end
    -- Version-zero prototypes stored the authored-id map directly.
    landings = copy_landings(payload.landings or payload)
    notify("apply")
    return true
end

function M.reset()
    landings = {}
    mirror_checkpoint_data()
    notify("defaults")
end

function M.subscribe(id, listener)
    if type(id) ~= "string" or id == "" or type(listener) ~= "function" then
        return false
    end
    listeners[id] = listener
    return true
end

function M.unsubscribe(id)
    if listeners[id] == nil then return false end
    listeners[id] = nil
    return true
end

function M.get_landing(elevator_id)
    local key = authored_key(elevator_id)
    return key and landings[key] or nil
end

function M.set_landing(elevator_id, stop)
    local key = authored_key(elevator_id)
    local normalized = State.normalize_stop(stop)
    if not key or not normalized then return false, "invalid_elevator_landing" end
    landings[key] = normalized
    mirror_checkpoint_data()
    return true
end

local function hydrate_loaded_checkpoint(Checkpoint)
    local data = Checkpoint and Checkpoint.data
    if type(data) ~= "table" then return end
    local payload = data.elevators
    local envelope = data.modules and data.modules[PROVIDER_ID]
    if type(envelope) == "table" and envelope.data ~= nil then
        payload = envelope.data
    end
    if type(payload) == "table" then M.apply_state(payload) end
end

function M.ensure_checkpoint_provider()
    if checkpoint_registered then return true end
    local Checkpoint = checkpoint_module()
    if not Checkpoint or type(Checkpoint.register_provider) ~= "function" then
        return false
    end

    hydrate_loaded_checkpoint(Checkpoint)
    local ok = pcall(Checkpoint.register_provider, PROVIDER_ID, {
        capture = function()
            return M.capture_state()
        end,
        apply = function(payload)
            M.apply_state(payload)
        end,
        defaults = function()
            M.reset()
        end,
        version = 1,
        order = 65,
        mirror_key = "elevators",
        description = "Elevator safe-landing registry",
    })
    checkpoint_registered = ok
    return ok
end

function M.is_checkpoint_registered()
    return checkpoint_registered
end

M.ensure_checkpoint_provider()

return M
