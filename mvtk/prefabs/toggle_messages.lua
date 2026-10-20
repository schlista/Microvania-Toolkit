-- Common enable/disable message handling for prefabs.

local M = {}

local MSG_SET_ENABLED = hash("set_enabled")
local MSG_ENABLE = hash("enable")
local MSG_DISABLE = hash("disable")

local function current_state(self, field)
    return self[field or "enabled"] == true
end

local function coerce_enabled(value, opts)
    if opts.truthy then
        return value ~= false
    end
    return value == true
end

function M.handle(self, message_id, message, apply, opts)
    if type(apply) ~= "function" then
        return false
    end
    opts = opts or {}

    if message_id == MSG_SET_ENABLED then
        local enabled = message and message.enabled
        if enabled == nil then
            enabled = not current_state(self, opts.field)
        end
        apply(self, coerce_enabled(enabled, opts), message_id, message)
        return true
    elseif message_id == MSG_ENABLE then
        apply(self, true, message_id, message)
        return true
    elseif message_id == MSG_DISABLE then
        apply(self, false, message_id, message)
        return true
    end

    return false
end

return M
